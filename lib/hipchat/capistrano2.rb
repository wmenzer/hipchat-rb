require 'hipchat'

# HipChat has rate limits (500 API request per 5 minutes), so make sure we don't make too many requests here, especially
# as we may use the same API token across multiple branches that could deploy at once
SLEEP_TIME = 10

Capistrano::Configuration.instance(:must_exist).load do
  set :hipchat_send_notification, false
  set :hipchat_with_migrations, ''

  namespace :hipchat do
    task :trigger_notification do
      set :hipchat_send_notification, true if !dry_run
    end

    task :configure_for_migrations do
      set :hipchat_with_migrations, ' (with migrations)'
    end

    task :notify_deploy_started do
      if hipchat_send_notification
        on_rollback do
          send_options.merge!(:color => failed_message_color)
          send("#{human} cancelled deployment of #{deployment_name} to #{environment_string}.", send_options)
        end

        if give_opportunity_to_cancel?
          wait_for_hipchat_cancellation
        else
          send("#{human} is deploying #{deployment_name} to #{environment_string}#{fetch(:hipchat_with_migrations, '')}.", send_options)
        end
      end
    end

    task :notify_deploy_finished do
      if hipchat_send_notification
        send_options.merge!(:color => success_message_color)

        if fetch(:hipchat_commit_log, false)
          logs = commit_logs
          unless logs.empty?
            send(logs.join(commit_log_line_separator), send_options)
          end
        end
        send("#{human} finished deploying #{deployment_name} to #{environment_string}#{fetch(:hipchat_with_migrations, '')}.", send_options)
      end
    end

    def send_options
      return @send_options if defined?(@send_options)
      @send_options = message_format ? {:message_format => message_format } : {}
      @send_options.merge!(:notify => message_notification)
      @send_options.merge!(:color => message_color)
      @send_options
    end

    def send(message, options)
      return unless enabled?

      hipchat_options = fetch(:hipchat_options, {})
      set :hipchat_client, HipChat::Client.new(hipchat_token, hipchat_options) if fetch(:hipchat_client, nil).nil?

      rooms.each { |room|
        begin
          hipchat_client[room].send(deploy_user, message, options)
        rescue => e
          puts e.message
          puts e.backtrace
        end
      }
    end

    def enabled?
      fetch(:hipchat_enabled, true)
    end

    def deployment_name
      if fetch(:branch, nil)
        name = "#{application}/#{branch}"
        name += " #{formatted_revision(real_revision[0..7])}" if real_revision
        name
      else
        application
      end
    end

    def message_color
      fetch(:hipchat_color, nil)
    end

    def success_message_color
      fetch(:hipchat_success_color, "green")
    end

    def failed_message_color
      fetch(:hipchat_failed_color, "red")
    end

    def message_notification
      fetch(:hipchat_announce, false)
    end

    def formatted_revision(revision)
      fetch(:hipchat_revision_format, '(revision %{revision})') % {revision: revision}
    end

    def message_format
      fetch(:hipchat_message_format, "html")
    end

    def deploy_user
      fetch(:hipchat_deploy_user, "Deploy")
    end

    def human
      ENV['HIPCHAT_USER'] ||
        fetch(:hipchat_human,
              if (u = %x{git config user.name}.strip) != ""
                u
              elsif (u = ENV['USER']) != ""
                u
              else
                "Someone"
              end)
    end

    def env
      fetch(:hipchat_env, fetch(:rack_env, fetch(:rails_env, "production")))
    end

    def commit_log_line_separator
      message_format == "html" ? "<br/>" : "\n"
    end

    def rooms
      return [hipchat_room_name] if hipchat_room_name.is_a?(String)
      return [hipchat_room_name.to_s] if hipchat_room_name.is_a?(Symbol)

      hipchat_room_name
    end

    def history(room)
      JSON.parse(hipchat_client[room].history())
    end

    def is_cancellation_message?(m)
      m['message'].include?('cancel deploy')
    end

    def is_deploy_message?(m)
      m['from'].include?('Deploy')
    end

    def found_cancellation_message?(room)
      messages_with_recent_first = history(room)['items'].reverse

      messages_with_recent_first.each do |m|
        return false if is_deploy_message?(m) # don't go back any further
        return true if is_cancellation_message?(m)
      end

      false
    end

    def environment_string
      self.respond_to?(:stage) ? "#{stage} (#{env})" : env
    end

    def wait_for_hipchat_cancellation
      send("@here #{human} is deploying #{deployment_name} to #{environment_string}#{fetch(:hipchat_with_migrations, '')}. Reply with a message containing 'cancel deploy' to cancel.  Otherwise, the deploy will proceed in #{cancellation_window} seconds.", send_options.merge(notify: true))
      puts "Allowing #{cancellation_window} seconds for users to cancel deploy via HipChat message."

      (cancellation_window / SLEEP_TIME).times do
        sleep(SLEEP_TIME)
        if rooms.any? { |room| found_cancellation_message?(room) }
          send("Cancelling deploy.", send_options)
          raise 'Cancelling deploy based on HipChat message'
        end
      end

      send("Proceeding with deploy of #{deployment_name}.", send_options)
      puts 'No HipChat message - proceeding with deploy.'
    end

    def give_opportunity_to_cancel?
      fetch(:hipchat_give_opportunity_to_cancel, false)
    end

    def cancellation_window
      fetch(:hipchat_cancellation_window, 180)
    end
  end

  def commit_logs
    from = (previous_revision rescue nil)
    to   = (latest_revision rescue nil)

    log_hashes = []
    case scm.to_s
    when 'git'
      logs = run_locally(source.local.scm(:log, "--no-merges --pretty=format:'%H$$%at$$%an$$%s' #{from}..#{to}"))
      logs.split(/\n/).each do |log|
        ll = log.split(/\$\$/)
        log_hashes << {revision: ll[0], time: Time.at(ll[1].to_i), user: ll[2], message: ll[3]}
      end
    when 'svn'
      logs = run_locally(source.local.scm(:log, "--non-interactive -r #{from}:#{to}"))
      logs.scan(/^[-]+$\n\s*(?<revision>[^\|]+)\s+\|\s+(?<user>[^\|]+)\s+\|\s+(?<time>[^\|]+)\s+.*\n+^\s*(?<message>.*)\s*$\n/) do |m|
        h = Regexp.last_match
        log_hashes << {revision: h[:revision], time: Time.parse(h[:time]), user: h[:user], message: h[:message]}
      end
    else
      puts "We haven't supported this scm yet."
      return []
    end

    format = fetch(:hipchat_commit_log_format, ":time :user\n:message\n")
    time_format = fetch(:hipchat_commit_log_time_format, "%Y/%m/%d %H:%M:%S")
    message_format = fetch(:hipchat_commit_log_message_format, nil)

    log_hashes.map do |log_hash|
      if message_format
        matches = log_hash[:message].match(/#{message_format}/)
        log_hash[:message] = if matches
                               matches[0]
                             else
                               ''
                             end
      end
      log_hash[:time] &&= log_hash[:time].localtime.strftime(time_format)
      log_hash.inject(format) do |l, (k, v)|
        l.gsub(/:#{k}/, v.to_s)
      end
    end
  end

  before "deploy", "hipchat:trigger_notification"
  before "deploy:migrations", "hipchat:trigger_notification", "hipchat:configure_for_migrations"
  before "deploy:update_code", "hipchat:notify_deploy_started"
  after  "deploy", "hipchat:notify_deploy_finished"
  after  "deploy:migrations", "hipchat:notify_deploy_finished"
end

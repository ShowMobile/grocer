require 'forwardable'

module Grocer
  class Pusher
    extend Forwardable

    def_delegators :@connection, :connect, :close

    def initialize(connection, options={})
      @connection = connection
    end

    # returns 4 arrays:
    #    sent        <- notifications we that have been sent
    #    maybe_sent  <- notifications that might have been sent
    #    failed      <- notifications that we got an error response for (currently this array can contain only one notification)
    #    not_sent    <- notifications that we were not sent because they happended after a notification that we got an error response for
    def push(notifications)
      notifications = [notifications] if notifications.is_a?(Grocer::Notification)
      return [], [], [], [] if !notifications.is_a?(Array) or notifications.count <= 0

      connect


      error_response = nil

      notification_index = 0
      notifications.each do |n|
        n.identifier = notification_index
        notification_index += 1

        # try to read error
        begin
          error_response = read_error(0, true)
          error_response = nil if error_response && error_response.status_code == 0
        rescue Exception => e
          # ok, we now got an exception while trying to read an error response
          # that means we cannot find out which notifications where really sent and which not
          return [], notifications[0..notification_index-1], [], [notification_index..notifications.count-1]
        end
        
        if error_response
          break

        else
          # write
          begin
            @connection.write(n.to_bytes)
            n.mark_sent
          rescue Exception => e
            break
          end
        end
      end

      # after we sent all notifications, we wait for 5 seconds to see if we still get a error reponse
      unless error_response
        error_response = read_error(5, false)
        error_response = nil if error_response && error_response.status_code == 0
        
        close
      end


      if error_response
        sent_notifications = []
        failed_notifications = []
        not_sent_notifications = []

        notifications.each do |n|
          if n.identifier.blank?
            not_sent_notifications << n
          elsif n.identifier < error_response.identifier
            sent_notifications << n
          elsif n.identifier == error_response.identifier
            n.error_response = error_response
            n.unmark_sent
            failed_notifications << n
          else
            n.unmark_sent
            not_sent_notifications << n
          end
        end

        return sent_notifications, [], failed_notifications, not_sent_notifications
      else
        return notifications, [], [], []
      end
    end

    def read_error(timeout=0, raise_exception=false)
      begin
        if response = @connection.read_if_ready(Grocer::ErrorResponse::LENGTH, timeout)
          close
          Grocer::ErrorResponse.from_binary(response)
        end
      rescue EOFError
        close
        if raise_exception
          raise
        else
          nil
        end
      end
    end

  end
    
end

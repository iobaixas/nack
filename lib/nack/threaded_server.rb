
require 'nack/server'
require 'thread'

module Nack

  class ThreadedServer < Server

    def self.run(*args)
      new(*args).start
    end

    def initialize(config, options = {})

      self.config = config
      self.file   = options[:file]
      self.ppid   = Process.ppid

      at_exit { close }

      self.server = UNIXServer.open(file)
      self.server.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)

      # TODO: Accept timeout: 3 secs (try with setsockopt SOL_SOCKET SO_RCVTIMEO)
      self.heartbeat = self.server.accept
      self.heartbeat.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)

      trap('TERM') { exit }
      trap('INT')  { exit }
      trap('QUIT') { close }

      self.app = load_config
    rescue Exception => e
      handle_exception(e)
    end

    def start

      # Heartbeat goes in a separate thread.
      Thread.new do
        begin
          heartbeat.write "#{$$}\n"
          heartbeat.flush
          heartbeat.read # TODO: Timeout
Rails.logger.info "heartbeat off!"
          close
        end
      end

      clients = [] # Store client threads so we can join later...
      mutex = Mutex.new

      loop do
        # TODO: Accept timeout
        client = server.accept
        client.fcntl(Fcntl::F_SETFD, Fcntl::FD_CLOEXEC)

        # TODO: Where to put this?
        # if ppid != Process.ppid
        #   return close
        # end

        # Create a new thread for every client.
        clients << Thread.new do
          buffer = sock.read # Is this the right way of passing the client to the thread? -> investigate!
          # TODO: There is a sock.close_read call in "handle" that causes problems if not commented, do something about it here.
          mutex.synchronize { handle sock, StringIO.new(buffer) }
        end
      end

      # Join clients
Rails.logger.info "Waiting for clients!"
      clients.each { |c| c.join }
      nil
    rescue SystemExit, Errno::EINTR
      # Ignore
    rescue Exception => e
      handle_exception(e)
    end
  end
end

# src/mcp/transports/stdio.cr
module MCP
  class StdioServerTransport < IOTransport
    def initialize(input : IO = STDIN, output : IO = STDOUT)
      super(input, output)
    end
  end

  class StdioClientTransport < Transport
    getter process : Process

    def initialize(command : String, args : Array(String) = [] of String,
                   env : Hash(String, String)? = nil, chdir : String? = nil)
      @process = Process.new(command, args, env: env, chdir: chdir,
        input: Process::Redirect::Pipe, output: Process::Redirect::Pipe,
        error: Process::Redirect::Inherit)
      @closed = Atomic(Bool).new(false)
      @send_mutex = Mutex.new
    end

    def send(message : String) : Nil
      raise RpcError.new(ErrorCodes::INTERNAL_ERROR, "stdio transport is closed") if closed?
      @send_mutex.synchronize do
        @process.input.puts(message)
        @process.input.flush
      end
    rescue ex : IO::Error
      close
      raise RpcError.new(ErrorCodes::INTERNAL_ERROR, "stdio write failed: #{ex.message}")
    end

    def read_message : String?
      loop do
        line = @process.output.gets
        return nil if line.nil?
        line = line.strip
        return line unless line.empty?
      end
    rescue ex : IO::Error
      nil
    end

    def close : Nil
      return if @closed.swap(true)
      begin
        @process.input.close
      rescue IO::Error
      end
      unless @process.terminated?
        @process.terminate
      end
    end

    def closed? : Bool
      @closed.get
    end
  end
end

# src/mcp/transport.cr
module MCP
  abstract class Transport
    abstract def send(message : String) : Nil
    abstract def read_message : String?
    abstract def close : Nil

    def closed? : Bool
      false
    end
  end

  class IOTransport < Transport
    def initialize(@input : IO, @output : IO, @on_close : Proc(Nil)? = nil)
      @closed = Atomic(Bool).new(false)
      @send_mutex = Mutex.new
    end

    def send(message : String) : Nil
      return if closed?
      @send_mutex.synchronize do
        @output.puts(message)
        @output.flush
      end
    rescue ex : IO::Error
      close
      raise ex
    end

    def read_message : String?
      loop do
        line = @input.gets
        return nil if line.nil?
        line = line.strip
        return line unless line.empty?
      end
    rescue ex : IO::Error
      nil
    end

    def close : Nil
      was = @closed.swap(true)
      return if was
      begin
        @output.close
      rescue IO::Error
      end
      @on_close.try(&.call)
    end

    def closed? : Bool
      @closed.get
    end
  end
end

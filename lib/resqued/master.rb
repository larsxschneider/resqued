require 'resqued/worker'

module ResqueDaemon
  class Master
    # List of queue definitions
    attr_reader :queues

    # Number of worker child processes to spawn.
    attr_accessor :worker_processes

    # Additional options passed to all worker objects created.
    # See Resque::Worker for a list of supported options and values.
    attr_reader :options

    def initialize(queues = {}, options = {})
      @queues = queues
      @options = options.dup
      options.keys.each { |k| respond_to?("#{k}=") && send("#{k}=", @options.delete(k)) }

      @worker_processes ||= 1
      @workers = []
    end

    # The main run loop. Maintains the worker pool.
    def run
      while true
        reap_workers
        build_workers
        spawn_workers
        sleep 0.100
      end
    end

    # Internal: Build an array of Worker objects with queue lists configured based
    # on the concurrency values established and the total number of workers. No
    # worker processes are spawned from this method. The #workers array is
    # guaranteed to be the size of the configured worker process count and there
    # is a Worker object in each slot.
    #
    # Returns nothing.
    def build_workers
      queues = fixed_concurrency_queues
      worker_processes.times do |slot|
        worker = workers[slot]
        if worker.nil? || worker.reaped?
          queue_names = queues.
            select { |name, concurrency| concurrency <= worker_number }.
            map    { |name, _| name }
          opts = default_worker_options.merge(@options)
          worker = ResqueDaemon::Worker.new(slot + 1, queue_names, opts)
        end
        workers[slot] = worker
      end
    end

    # Internal: Fork off any unspawned worker processes. Ignore worker processes
    # that have already been spawned, even if their process isn't running
    # anymore.
    def spawn_workers
      workers.each do |worker|
        next if worker.pid?
        worker.spawn
      end
    end

    # Internal: Attempt to reap process exit codes from all workers that have
    # exited. Ignore workers that haven't been spawned yet or have already been
    # reaped.
    def reap_workers
      workers.each do |worker|
        next if !worker.running?
        worker.reap
      end
    end

    # Internal: Like #queues but with concrete fixed concurrency values. All
    # percentage based concurrency values are converted to fixnum total number
    # of workers that queue should run on.
    def fixed_concurrency_queues
      queues.map { |name, concurrency| [name, translate_concurrency_value(concurrency)] }
    end

    # Internal: Convert a queue worker concurrency value to a fixed number of
    # workers. This supports values that are fixed numbers as well as percentage
    # values (between 0.0 and 1.0). The value may also be nil, in which case the
    # maximum worker_processes value is returned.
    def translate_concurrency_value(value)
      case
      when value.nil?
        worker_processes
      when value.is_a?(Fixnum)
        value < worker_processes ? value : worker_processes
      when value.is_a?(Float) && value >= 0.0 && value <= 1.0
        (worker_processes * value).to_i
      else
        raise TypeError, "Unknown concurrency value: #{value.inspect}"
      end
    end
  end
end

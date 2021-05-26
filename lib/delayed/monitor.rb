module Delayed
  class Monitor
    include Runnable

    METRICS = %w(
      count
      future_count
      locked_count
      erroring_count
      failed_count
      max_lock_age
      max_age
      working_count
      workable_count
    ).freeze

    cattr_accessor(:sleep_delay) { 60 }

    def initialize
      @jobs = Job.group(priority_case_statement).group(:queue)
      @jobs = @jobs.where(queue: Worker.queues) if Worker.queues.any?
      @as_of = Job.db_time_now
    end

    def run!
      ActiveSupport::Notifications.instrument('delayed.monitor.run', default_tags) do
        METRICS.each { |metric| emit_metric!(metric) }
      end
    end

    private

    attr_reader :jobs, :as_of

    def emit_metric!(metric)
      send("#{metric}_grouped").reverse_merge(default_results).each do |(priority, queue), value|
        ActiveSupport::Notifications.instrument(
          "delayed.job.#{metric}",
          default_tags.merge(priority: priority, queue: queue, value: value),
        )
      end
    end

    def default_results
      @default_results ||= Priority.names.flat_map { |priority, _|
        (Worker.queues.presence || [Worker.default_queue_name]).map do |queue|
          [[priority.to_s, queue], 0]
        end
      }.to_h
    end

    def say(message)
      Worker.logger.send(Worker.default_log_level, message)
    end

    def default_tags
      @default_tags ||= {
        table: Job.table_name,
        database: connection_config[:database],
        database_adapter: connection_config[:adapter],
      }
    end

    def connection_config
      Plugins::Instrumentation.connection_config(Job)
    end

    def count_grouped
      jobs.count
    end

    def future_count_grouped
      jobs.where("run_at > ?", as_of).count
    end

    def locked_count_grouped
      jobs.claimed.count
    end

    def erroring_count_grouped
      jobs.erroring.count
    end

    def failed_count_grouped
      jobs.failed.count
    end

    def max_lock_age_grouped
      oldest_locked_job_grouped.each_with_object({}) do |job, metrics|
        metrics[[job.priority_name, job.queue]] = as_of - job.locked_at
      end
    end

    def max_age_grouped
      oldest_workable_job_grouped.each_with_object({}) do |job, metrics|
        metrics[[job.priority_name, job.queue]] = as_of - job.run_at
      end
    end

    def workable_count_grouped
      jobs.workable(as_of).count
    end

    def working_count_grouped
      jobs.working.count
    end

    def oldest_locked_job_grouped
      jobs.working.select("#{priority_case_statement} AS priority_name, queue, MIN(locked_at) AS locked_at")
    end

    def oldest_workable_job_grouped
      jobs.workable(as_of).select("#{priority_case_statement} AS priority_name, queue, MIN(run_at) AS run_at")
    end

    def priority_case_statement
      [
        'CASE',
        Priority.ranges.map do |(name, range)|
          [
            "WHEN priority >= #{range.first.to_i}",
            ("AND priority < #{range.last.to_i}" unless range.last.infinite?),
            "THEN '#{name}'",
          ].compact
        end,
        'END',
      ].flatten.join(' ')
    end
  end
end
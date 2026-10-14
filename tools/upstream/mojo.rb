# Local deployment adapter for the pinned, independent verification runner.
# No response oracle or browser assertion lives here.
require "set"

module MojoVerification
  extend BenchmarkSupport

  def self.configure(config, port, data)
    required = {
      "PORT" => port.to_s, "BIND_ADDRESS" => "127.0.0.1",
      "PUBLIC_ORIGIN" => "http://127.0.0.1:#{port}",
      "DATABASE_PATH" => File.join(data, "db/production.sqlite3"),
      "STORAGE_PATH" => File.join(data, "files"), "PUBLIC_PATH" => "/app/public",
      "CAMPFIRE_SQLITE_SYNCHRONOUS" => "FULL", "CAMPFIRE_JOB_RECEIPTS" => "1",
      "CAMPFIRE_JOBS_PAUSED" => "0"
    }
    required.each do |key, value|
      raise "Mojo verification requires #{key}=#{value}" if config.key?(key) && config[key] != value
    end
    config.merge(required)
  end

  def self.topology(config)
    {http_workers: config.fetch("MOJO_WORKERS", "4"), job_workers: config.fetch("JOB_CONCURRENCY"),
      jobs: "transactional SQLite outbox", cable: "native", synchronous: "FULL"}
  end

  def self.mounts
    volume = ENV.fetch("MOJO_VERIFICATION_VOLUME")
    root = ENV.fetch("MOJO_VERIFICATION_RUNTIME")
    ["--mount", "type=volume,source=#{volume},target=#{root}"]
  end

  def self.prepare(data)
    # The production image runs as uid 10001. Only these disposable copies change.
    FileUtils.chown_R(10001, 10001, data)
  end

  def self.snapshot(sql, db, room, author)
    subscriptions = sql.call(db, "SELECT ps.id FROM push_subscriptions ps JOIN memberships mm ON mm.user_id=ps.user_id JOIN users u ON u.id=ps.user_id WHERE mm.room_id=#{Integer(room)} AND mm.user_id<>#{Integer(author)} AND u.status=0 AND mm.involvement='everything' AND (mm.connected_at IS NULL OR mm.connected_at<datetime('now','-60 seconds'))").map { |row| row.fetch("id") }.to_set
    raise "fixture has no notification recipients" if subscriptions.empty?
    subscriptions
  end

  def self.completed(sql, db, room, baseline, acknowledged, subscriptions)
    expected = sql.call(db, "SELECT id FROM messages WHERE room_id=#{Integer(room)} AND id>#{Integer(baseline)}").map { |row| row.fetch("id") }.to_set
    raise "durable message count mismatch" unless expected.size == acknowledged
    pending = sql.call(db, "SELECT failed,error,attempts FROM mojo_jobs")
    raise "failed or retried background job" if pending.any? { |job| job.fetch("failed") != 0 || job["error"] || job.fetch("attempts") > 1 }
    completed = sql.call(db, "SELECT message_id FROM campfire_completed_jobs WHERE kind='message'").map { |row| row.fetch("message_id") }.to_set
    receipts = sql.call(db, "SELECT message_id,target_id FROM campfire_delivery_receipts WHERE kind='push'").map { |row| [row.fetch("message_id"), row.fetch("target_id")] }.to_set
    wanted = expected.to_a.product(subscriptions.to_a).to_set
    # Unexpected work is a failure, even while the queue is still draining.
    raise "unexpected completed background job" unless completed.subset?(expected)
    raise "unexpected notification receipt" unless receipts.subset?(wanted)
    return nil unless pending.empty?
    raise "missing completed background jobs" unless completed == expected
    raise "missing notification receipts" unless receipts == wanted
    {pending: 0, failed: 0, completed_messages: completed.size, completed_notifications: receipts.size}
  end

  def self.validate_shutdown(log, state)
    raise "Mojo server reported a failure" if log.match?(/Request failed:|Background job failed:|Worker (?:failed:|exited unexpectedly)|queue full|dropping job|KGEN_CompilerRT_DestroyGlobals|Segmentation fault/i)
    raise "Mojo server did not stop cleanly" unless state.fetch("ExitCode").zero? && !state.fetch("OOMKilled")
  end

  def self.stop(container, log)
    run("docker", "stop", "--time", "30", container)
    output, errors, status = Open3.capture3("docker", "logs", container)
    FileUtils.mkdir_p(File.dirname(log))
    File.write(log, output + errors)
    raise "Cannot read Mojo server log" unless status.success?
    state = JSON.parse(run("docker", "inspect", "-f", "{{json .State}}", container))
    validate_shutdown(File.read(log), state)
  end

  def self.capture_failure(container, output)
    logs, errors, status = Open3.capture3("docker", "logs", container)
    FileUtils.mkdir_p(output)
    File.write(File.join(output, "failure-server.log"), logs + errors)
    warn "Could not capture server logs" unless status.success?
  end

  def self.finish(sql, db, room, baseline, acknowledged, subscriptions, container, log)
    deadline = clock + 180
    loop do
      result = completed(sql, db, room, baseline, acknowledged, subscriptions)
      if result
        stop(container, log)
        return result
      end
      raise "Mojo background jobs did not drain" if clock > deadline
      sleep 0.05
    end
  end
end

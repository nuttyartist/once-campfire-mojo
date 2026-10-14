require "minitest/autorun"
require "tmpdir"
verification = ARGV.shift or abort "pass the pinned verification checkout"
require File.join(verification, "bench/comparison_support")
require_relative "../tools/upstream/mojo"

class UpstreamAdapterTest < Minitest::Test

  def setup
    @directory = Dir.mktmpdir
    @db = File.join(@directory, "fixture.sqlite3")
    @sql = ->(db, query) do
      output = MojoVerification.run("sqlite3", "-json", db, query)
      output.strip.empty? ? [] : JSON.parse(output)
    end
    @sql.call(@db, <<~SQL)
      CREATE TABLE messages(id INTEGER,room_id INTEGER);
      CREATE TABLE mojo_jobs(failed INTEGER,error TEXT,attempts INTEGER);
      CREATE TABLE campfire_completed_jobs(message_id INTEGER,kind TEXT);
      CREATE TABLE campfire_delivery_receipts(message_id INTEGER,target_id INTEGER,kind TEXT);
      INSERT INTO messages VALUES(42,2);
      INSERT INTO campfire_completed_jobs VALUES(42,'message');
      INSERT INTO campfire_delivery_receipts VALUES(42,7,'push'),(42,8,'push');
    SQL
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def completion
    MojoVerification.completed(@sql, @db, 2, 40, 1, Set[7,8])
  end

  def test_crash_and_oom_are_rejected
    [{"ExitCode" => 137, "OOMKilled" => false}, {"ExitCode" => 0, "OOMKilled" => true}].each do |state|
      assert_raises(RuntimeError) { MojoVerification.validate_shutdown("", state) }
    end
  end

  def test_worker_or_delivery_log_failure_is_rejected_even_after_clean_exit
    ["Background job failed: delivery", "Worker exited unexpectedly", "queue full", "Request failed: SQL"].each do |log|
      assert_raises(RuntimeError) { MojoVerification.validate_shutdown(log, {"ExitCode" => 0, "OOMKilled" => false}) }
    end
  end

  def test_normal_server_log_passes
    MojoVerification.validate_shutdown("Campfire Mojo listening on 127.0.0.1", {"ExitCode" => 0, "OOMKilled" => false})
    assert true
  end

  def test_full_and_receipts_are_mandatory
    config = MojoVerification.configure({}, 25130, @directory)
    assert_equal "FULL", config.fetch("CAMPFIRE_SQLITE_SYNCHRONOUS")
    assert_equal "1", config.fetch("CAMPFIRE_JOB_RECEIPTS")
    {"CAMPFIRE_SQLITE_SYNCHRONOUS" => "NORMAL", "CAMPFIRE_JOB_RECEIPTS" => "0", "CAMPFIRE_JOBS_PAUSED" => "1"}.each do |key, value|
      assert_raises(RuntimeError) { MojoVerification.configure({key => value}, 25130, @directory) }
    end
  end

  def test_storage_cannot_be_redirected_outside_disposable_data
    config = MojoVerification.configure({}, 25130, @directory)
    assert_equal File.join(@directory, "db/production.sqlite3"), config.fetch("DATABASE_PATH")
    assert_equal File.join(@directory, "files"), config.fetch("STORAGE_PATH")
    ["DATABASE_PATH", "STORAGE_PATH"].each do |key|
      assert_raises(RuntimeError) { MojoVerification.configure({key => "/user-data"}, 25130, @directory) }
    end
  end

  def test_complete_work_passes
    assert_equal({pending: 0, failed: 0, completed_messages: 1, completed_notifications: 2}, completion)
  end

  def test_pending_work_is_not_success
    @sql.call(@db, "INSERT INTO mojo_jobs VALUES(0,NULL,1)")
    assert_nil completion
  end

  def test_failed_and_retried_jobs_are_rejected
    ["1,NULL,1", "0,'delivery failed',1", "0,NULL,2"].each do |row|
      @sql.call(@db, "DELETE FROM mojo_jobs; INSERT INTO mojo_jobs VALUES(#{row})")
      assert_raises(RuntimeError) { completion }
    end
  end

  def test_dropped_jobs_are_rejected
    @sql.call(@db, "DELETE FROM campfire_completed_jobs")
    assert_raises(RuntimeError) { completion }
  end

  def test_missing_receipt_is_rejected
    @sql.call(@db, "DELETE FROM campfire_delivery_receipts WHERE target_id=8")
    assert_raises(RuntimeError) { completion }
  end

  def test_wrong_receipt_with_same_count_is_rejected
    @sql.call(@db, "UPDATE campfire_delivery_receipts SET target_id=9 WHERE target_id=8")
    assert_raises(RuntimeError) { completion }
  end

  def test_unexpected_completion_is_rejected
    @sql.call(@db, "INSERT INTO campfire_completed_jobs VALUES(43,'message')")
    assert_raises(RuntimeError) { completion }
  end

  def test_unacknowledged_message_is_rejected
    @sql.call(@db, "INSERT INTO messages VALUES(43,2)")
    assert_raises(RuntimeError) { completion }
  end
end

# frozen_string_literal: true

# Deterministic waits for the race tests: instead of sleeping and hoping a thread has
# reached its lock, ask the database whether that thread's connection is blocked on a
# lock right now (PostgreSQL: pg_blocking_pids; MySQL: information_schema.innodb_trx
# in LOCK WAIT), polling for up to `timeout` seconds and failing loudly otherwise.
module LockWaits
  # The database's id for the connection the calling thread holds.
  def backend_id
    connection = ActiveRecord::Base.connection
    case connection.adapter_name.downcase
    when /postg/ then connection.select_value("SELECT pg_backend_pid()")
    when /mysql|trilogy/ then connection.select_value("SELECT CONNECTION_ID()")
    else raise "LockWaits needs PostgreSQL or MySQL"
    end.to_i
  end

  # Wait until the connection `id` waits on a lock (asked from this thread's own,
  # separate connection).
  def wait_until_blocked(id, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until blocked?(id)
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        flunk "connection #{id} was never blocked on a lock within #{timeout}s"
      end
      sleep 0.01
    end
  end

  private

  # Uncached: the same SELECT, asked again, must reach the database (the test
  # executor's query cache would otherwise answer every poll with the first result).
  def blocked?(id)
    ActiveRecord::Base.uncached { blocked_now?(id) }
  end

  def blocked_now?(id)
    connection = ActiveRecord::Base.connection
    case connection.adapter_name.downcase
    when /postg/
      connection.select_value("SELECT cardinality(pg_blocking_pids(#{Integer(id)})) > 0")
    else
      connection.select_value(
        "SELECT COUNT(*) FROM information_schema.innodb_trx " \
        "WHERE trx_mysql_thread_id = #{Integer(id)} AND trx_state = 'LOCK WAIT'"
      ).to_i.positive?
    end
  end
end

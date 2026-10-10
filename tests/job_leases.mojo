# Exercise the actual worker operations, including read-only admission and rollback.
from database import Database
import jobs


def require(value: Bool, message: String) raises:
    if not value:
        raise Error(message)


def main() raises:
    var db = Database(":memory:")
    _ = db.rows(
        "CREATE TABLE mojo_jobs(id INTEGER PRIMARY KEY, message_id INTEGER, hooks INTEGER DEFAULT 1, kind TEXT DEFAULT 'message', attempts INTEGER DEFAULT 0, available_at INTEGER DEFAULT 0, lease_until INTEGER DEFAULT 0, failed INTEGER DEFAULT 0)"
    )
    _ = db.rows("CREATE INDEX mojo_jobs_ready ON mojo_jobs(id) WHERE failed=0")
    _ = db.rows("PRAGMA query_only=ON")
    require(
        len(jobs.claim(db)) == 0,
        "empty polling must work on a read-only connection",
    )
    _ = db.rows("PRAGMA query_only=OFF")
    _ = db.rows(
        "INSERT INTO mojo_jobs(id,message_id,available_at,lease_until,failed) VALUES(1,101,0,unixepoch()+600,0),(2,102,unixepoch()+600,0,0),(3,103,0,0,1)"
    )
    _ = db.rows("PRAGMA query_only=ON")
    require(
        len(jobs.claim(db)) == 0,
        "leased, delayed and failed jobs are ineligible without taking a write lock",
    )
    var lease = db.scalar("SELECT lease_until FROM mojo_jobs WHERE id=1")
    var changes = db.scalar("SELECT total_changes()")
    for i in range(100):
        jobs.renew(db, "1")
    jobs.renew(db, "")
    jobs.renew(db, "999")
    require(
        db.scalar("SELECT total_changes()") == changes,
        "fresh leases must not write",
    )
    require(
        db.scalar("SELECT lease_until FROM mojo_jobs WHERE id=1") == lease,
        "fresh leases must remain unchanged",
    )
    _ = db.rows("PRAGMA query_only=OFF")
    _ = db.rows("UPDATE mojo_jobs SET lease_until=unixepoch()+299 WHERE id=1")
    var expiring = db.scalar("SELECT lease_until FROM mojo_jobs WHERE id=1")
    _ = db.rows("BEGIN IMMEDIATE")
    jobs.renew(db, "1")
    require(
        db.scalar(
            "SELECT lease_until-unixepoch()>=599 FROM mojo_jobs WHERE id=1"
        )
        == "1",
        "renewal must restore the ten-minute lease",
    )
    _ = db.rows("ROLLBACK")
    require(
        db.scalar("SELECT lease_until FROM mojo_jobs WHERE id=1") == expiring,
        "lease renewal rolls back with its transaction",
    )
    jobs.renew(db, "1")
    require(
        db.scalar(
            "SELECT lease_until-unixepoch()>=599 FROM mojo_jobs WHERE id=1"
        )
        == "1",
        "rollback must not leave a cached renewal that suppresses a real renewal",
    )
    _ = db.rows("UPDATE mojo_jobs SET available_at=0 WHERE id=2")
    var claimed = jobs.claim(db)
    require(
        len(claimed) == 1
        and claimed[0][0] == "2"
        and claimed[0][1] == "102"
        and claimed[0][3] == "1",
        "claim must return only the eligible job and increment attempts",
    )
    require(len(jobs.claim(db)) == 0, "claimed jobs cannot be claimed twice")
    _ = db.rows("UPDATE mojo_jobs SET lease_until=unixepoch()-1 WHERE id=2")
    claimed = jobs.claim(db)
    require(
        len(claimed) == 1 and claimed[0][3] == "2",
        "expired claims must remain recoverable",
    )
    print(
        "PASS: read-only polling, eligibility, bounded lease renewal, rollback and reclaim"
    )

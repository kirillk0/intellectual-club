use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, bail, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[derive(Clone, Debug)]
pub(crate) struct ContainerRecord {
    pub root_chat_id: i64,
    pub user_id: i64,
    pub generation: i64,
    pub container_id: Option<String>,
    pub container_name: String,
    pub status: String,
    pub last_used_at: i64,
    pub active_calls: i64,
    pub reset_reason: Option<String>,
    pub notice_pending: bool,
}

pub(crate) struct Store {
    connection: Connection,
    pub runner_id: String,
}

impl Store {
    pub fn open(path: &Path, server_url: &str, token: &str) -> Result<Self> {
        let mut connection = Connection::open(path).context("failed to open container database")?;
        connection.busy_timeout(Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS containers (
               root_chat_id INTEGER PRIMARY KEY,
               user_id INTEGER NOT NULL,
               generation INTEGER NOT NULL,
               container_id TEXT,
               container_name TEXT NOT NULL UNIQUE,
               image_id TEXT,
               status TEXT NOT NULL CHECK (status IN ('creating','ready','deleting','destroyed')),
               created_at INTEGER NOT NULL,
               last_used_at INTEGER NOT NULL,
               active_calls INTEGER NOT NULL DEFAULT 0 CHECK (active_calls >= 0),
               destroyed_at INTEGER,
               reset_reason TEXT,
               notice_pending INTEGER NOT NULL DEFAULT 0
             );",
        )?;
        let binding = format!(
            "{}\n{:x}",
            server_url.trim().trim_end_matches('/'),
            Sha256::digest(token.trim().as_bytes())
        );
        let transaction = connection.transaction()?;
        let stored_binding: Option<String> = transaction
            .query_row("SELECT value FROM metadata WHERE key='binding'", [], |r| {
                r.get(0)
            })
            .optional()?;
        match stored_binding {
            Some(value) if value != binding => bail!(
                "container database belongs to a different server or outlet token; use a separate data directory"
            ),
            None => {
                transaction.execute(
                    "INSERT INTO metadata(key,value) VALUES ('binding', ?1)",
                    [&binding],
                )?;
            }
            _ => {}
        }
        let runner_id: String = transaction
            .query_row(
                "SELECT value FROM metadata WHERE key='runner_id'",
                [],
                |r| r.get(0),
            )
            .optional()?
            .unwrap_or_else(|| Uuid::new_v4().simple().to_string());
        transaction.execute(
            "INSERT OR IGNORE INTO metadata(key,value) VALUES ('runner_id', ?1)",
            [&runner_id],
        )?;
        transaction.commit()?;
        Ok(Self {
            connection,
            runner_id,
        })
    }

    pub fn get(&self, root_chat_id: i64) -> Result<Option<ContainerRecord>> {
        Ok(self
            .connection
            .query_row(
                "SELECT root_chat_id,user_id,generation,container_id,container_name,status,
                    last_used_at,active_calls,reset_reason,notice_pending
             FROM containers WHERE root_chat_id=?1",
                [root_chat_id],
                decode_record,
            )
            .optional()?)
    }

    pub fn records(&self) -> Result<Vec<ContainerRecord>> {
        let mut statement = self.connection.prepare(
            "SELECT root_chat_id,user_id,generation,container_id,container_name,status,
                    last_used_at,active_calls,reset_reason,notice_pending
             FROM containers ORDER BY last_used_at, root_chat_id",
        )?;
        let records = statement
            .query_map([], decode_record)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(records)
    }

    pub fn reserve_creation(
        &mut self,
        root_chat_id: i64,
        user_id: i64,
        now: i64,
    ) -> Result<ContainerRecord> {
        let previous = self.get(root_chat_id)?;
        if let Some(previous) = &previous {
            if previous.user_id != user_id {
                bail!("workspace belongs to a different user");
            }
            if previous.status != "destroyed" {
                bail!("cannot replace a workspace before its previous container is destroyed");
            }
        }
        let generation = previous.as_ref().map_or(Ok(1), |r| {
            r.generation
                .checked_add(1)
                .ok_or_else(|| anyhow!("container generation overflow"))
        })?;
        let name = format!("ic-task-{}-{root_chat_id}-{generation}", self.runner_id);
        let reset_reason = previous.as_ref().and_then(|r| r.reset_reason.clone());
        self.connection.execute(
            "INSERT INTO containers
               (root_chat_id,user_id,generation,container_name,status,created_at,last_used_at,reset_reason,notice_pending)
             VALUES (?1,?2,?3,?4,'creating',?5,?5,?6,?7)
             ON CONFLICT(root_chat_id) DO UPDATE SET
               generation=excluded.generation,container_id=NULL,container_name=excluded.container_name,
               image_id=NULL,status='creating',created_at=excluded.created_at,last_used_at=excluded.last_used_at,
               active_calls=0,destroyed_at=NULL,reset_reason=excluded.reset_reason,notice_pending=excluded.notice_pending",
            params![root_chat_id,user_id,generation,name,now,reset_reason,previous.is_some()],
        )?;
        self.get(root_chat_id)?
            .ok_or_else(|| anyhow!("missing reserved container record"))
    }

    pub fn ready(
        &self,
        root_chat_id: i64,
        generation: i64,
        id: &str,
        image_id: &str,
    ) -> Result<()> {
        let changed = self.connection.execute(
            "UPDATE containers SET container_id=?3,image_id=?4,status='ready'
             WHERE root_chat_id=?1 AND generation=?2 AND status='creating'",
            params![root_chat_id, generation, id, image_id],
        )?;
        ensure_changed(changed)
    }

    pub fn acquire(&self, root_chat_id: i64, generation: i64, now: i64) -> Result<ContainerRecord> {
        let changed = self.connection.execute(
            "UPDATE containers SET active_calls=active_calls+1,last_used_at=MAX(last_used_at,?3)
             WHERE root_chat_id=?1 AND generation=?2 AND status='ready'",
            params![root_chat_id, generation, now],
        )?;
        ensure_changed(changed)?;
        self.get(root_chat_id)?
            .ok_or_else(|| anyhow!("missing acquired container record"))
    }

    pub fn release(&self, root_chat_id: i64, generation: i64, now: i64) -> Result<()> {
        self.release_with_notice(root_chat_id, generation, now, true)
    }

    pub fn release_without_notice(
        &self,
        root_chat_id: i64,
        generation: i64,
        now: i64,
    ) -> Result<()> {
        self.release_with_notice(root_chat_id, generation, now, false)
    }

    fn release_with_notice(
        &self,
        root_chat_id: i64,
        generation: i64,
        now: i64,
        acknowledge_notice: bool,
    ) -> Result<()> {
        // A lease from a destroyed generation must never alter a replacement workspace.
        self.connection.execute(
            "UPDATE containers SET active_calls=MAX(0,active_calls-1),
               last_used_at=MAX(last_used_at,?3),notice_pending=CASE WHEN ?4 THEN 0 ELSE notice_pending END
             WHERE root_chat_id=?1 AND generation=?2 AND status='ready'",
            params![root_chat_id, generation, now, acknowledge_notice],
        )?;
        Ok(())
    }

    pub fn deleting(&self, root_chat_id: i64, generation: i64, reason: &str) -> Result<()> {
        let changed = self.connection.execute(
            "UPDATE containers SET status='deleting',reset_reason=?3,notice_pending=1
             WHERE root_chat_id=?1 AND generation=?2 AND status!='destroyed'",
            params![root_chat_id, generation, reason],
        )?;
        ensure_changed(changed)
    }

    pub fn destroyed(
        &self,
        root_chat_id: i64,
        generation: i64,
        reason: &str,
        now: i64,
    ) -> Result<()> {
        let changed = self.connection.execute(
            "UPDATE containers SET status='destroyed',destroyed_at=?4,
               reset_reason=?3,notice_pending=1,active_calls=0
             WHERE root_chat_id=?1 AND generation=?2",
            params![root_chat_id, generation, reason, now],
        )?;
        ensure_changed(changed)
    }
}

fn ensure_changed(changed: usize) -> Result<()> {
    if changed != 1 {
        bail!("container database lifecycle conflict");
    }
    Ok(())
}

fn decode_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<ContainerRecord> {
    Ok(ContainerRecord {
        root_chat_id: row.get(0)?,
        user_id: row.get(1)?,
        generation: row.get(2)?,
        container_id: row.get(3)?,
        container_name: row.get(4)?,
        status: row.get(5)?,
        last_used_at: row.get(6)?,
        active_calls: row.get(7)?,
        reset_reason: row.get(8)?,
        notice_pending: row.get(9)?,
    })
}

pub(crate) fn now_millis() -> Result<i64> {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system clock is before the Unix epoch")?
        .as_millis();
    i64::try_from(millis).context("system clock is out of range")
}

pub(crate) fn eviction_eligible(record: &ContainerRecord, now: i64, ttl: Duration) -> bool {
    let ttl_ms = i64::try_from(ttl.as_millis()).unwrap_or(i64::MAX);
    record.status == "ready"
        && record.active_calls == 0
        && now.saturating_sub(record.last_used_at) >= ttl_ms
        && now >= record.last_used_at
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ready(store: &mut Store, root: i64, now: i64) -> ContainerRecord {
        let row = store.reserve_creation(root, 7, now).unwrap();
        store
            .ready(root, row.generation, &format!("container-{root}"), "image")
            .unwrap();
        store.get(root).unwrap().unwrap()
    }

    #[test]
    fn durable_identity_last_use_and_death_survive_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let runner_id;
        {
            let mut store = Store::open(&path, "http://server/", "token").unwrap();
            runner_id = store.runner_id.clone();
            let row = ready(&mut store, 42, 100);
            store.acquire(42, row.generation, 200).unwrap();
            store.release(42, row.generation, 300).unwrap();
        }
        let store = Store::open(&path, "http://server", "token").unwrap();
        assert_eq!(store.runner_id, runner_id);
        assert_eq!(store.get(42).unwrap().unwrap().last_used_at, 300);
        store.destroyed(42, 1, "container_missing", 400).unwrap();
        drop(store);
        let mut store = Store::open(&path, "http://server", "token").unwrap();
        let replacement = store.reserve_creation(42, 7, 500).unwrap();
        assert_eq!(replacement.generation, 2);
        assert!(replacement.notice_pending);
        assert_eq!(
            replacement.reset_reason.as_deref(),
            Some("container_missing")
        );
    }

    #[test]
    fn database_cannot_be_reused_for_another_outlet() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        drop(Store::open(&path, "http://server", "token").unwrap());
        assert!(Store::open(&path, "http://server", "another-token").is_err());
        assert!(Store::open(&path, "http://another-server", "token").is_err());
        assert!(Store::open(&path, "http://server", "token").is_ok());
    }

    #[test]
    fn busy_leases_protect_ttl_and_release_touches_at_completion() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite"), "s", "t").unwrap();
        ready(&mut store, 42, 0);
        store.acquire(42, 1, 100).unwrap();
        store.acquire(42, 1, 110).unwrap();
        let row = store.get(42).unwrap().unwrap();
        assert!(!eviction_eligible(&row, 100_000, Duration::from_secs(1)));
        store.release(42, 1, 100_001).unwrap();
        assert_eq!(store.get(42).unwrap().unwrap().active_calls, 1);
        store.release(42, 1, 100_002).unwrap();
        let row = store.get(42).unwrap().unwrap();
        assert!(!eviction_eligible(&row, 100_100, Duration::from_secs(1)));
        assert!(eviction_eligible(&row, 101_002, Duration::from_secs(1)));
        assert!(!eviction_eligible(&row, 90_000, Duration::ZERO));
    }

    #[test]
    fn old_lease_cannot_touch_replacement_and_user_cannot_change() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite"), "s", "t").unwrap();
        ready(&mut store, 42, 100);
        store.acquire(42, 1, 100).unwrap();
        store.destroyed(42, 1, "canceled", 200).unwrap();
        assert!(store.reserve_creation(42, 8, 300).is_err());
        let row = store.reserve_creation(42, 7, 300).unwrap();
        store
            .ready(42, row.generation, "replacement", "image")
            .unwrap();
        store.acquire(42, 2, 300).unwrap();
        store.release(42, 1, 999).unwrap();
        let row = store.get(42).unwrap().unwrap();
        assert_eq!(row.active_calls, 1);
        assert_eq!(row.last_used_at, 300);
        assert!(row.notice_pending);
    }

    #[test]
    fn canceled_allocation_preserves_unreported_reset_notice() {
        let dir = tempfile::tempdir().unwrap();
        let mut store = Store::open(&dir.path().join("state.sqlite"), "s", "t").unwrap();
        ready(&mut store, 42, 100);
        store.destroyed(42, 1, "container_missing", 200).unwrap();
        let row = store.reserve_creation(42, 7, 300).unwrap();
        store
            .ready(42, row.generation, "replacement", "image")
            .unwrap();
        store.acquire(42, 2, 400).unwrap();
        store.release_without_notice(42, 2, 500).unwrap();
        let row = store.get(42).unwrap().unwrap();
        assert_eq!(row.active_calls, 0);
        assert_eq!(row.last_used_at, 500);
        assert!(row.notice_pending);
        store.acquire(42, 2, 600).unwrap();
        store.release(42, 2, 700).unwrap();
        assert!(!store.get(42).unwrap().unwrap().notice_pending);
    }

    #[test]
    fn lru_order_is_last_access_not_creation_and_intents_persist() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.sqlite");
        let mut store = Store::open(&path, "s", "t").unwrap();
        ready(&mut store, 1, 10);
        ready(&mut store, 2, 20);
        store.acquire(1, 1, 30).unwrap();
        store.release(1, 1, 40).unwrap();
        store.reserve_creation(3, 7, 50).unwrap();
        drop(store);
        let store = Store::open(&path, "s", "t").unwrap();
        assert_eq!(
            store
                .records()
                .unwrap()
                .iter()
                .map(|r| r.root_chat_id)
                .collect::<Vec<_>>(),
            [2, 1, 3]
        );
        assert_eq!(store.get(3).unwrap().unwrap().status, "creating");
    }
}

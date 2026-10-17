use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use bollard::container::{
    Config, CreateContainerOptions, InspectContainerOptions, ListContainersOptions,
    RemoveContainerOptions, StartContainerOptions,
};
use bollard::errors::Error as DockerError;
use bollard::exec::{CreateExecOptions, StartExecResults};
use bollard::image::CreateImageOptions;
use bollard::models::{ContainerInspectResponse, HostConfig, HostConfigLogConfig};
use bollard::Docker;
use fs2::FileExt;
use futures_util::{StreamExt, TryStreamExt};
use outlet_core::ExecutionOutcomeUnknown;
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::process;
use crate::store::{eviction_eligible, now_millis, ContainerRecord, Store};

pub const RUNNER_LABEL: &str = "org.intellectual-club.task-runner";
pub const ROOT_LABEL: &str = "org.intellectual-club.root-chat-id";
pub const GENERATION_LABEL: &str = "org.intellectual-club.container-generation";

/// Upper bound for the in-container helper that stops one command's processes.
const STOP_DEADLINE: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub struct ContainerConfig {
    pub data_dir: PathBuf,
    pub image: String,
    pub max_containers: usize,
    pub max_disk_bytes: u64,
    pub guaranteed_ttl: Duration,
    pub memory_bytes: i64,
    pub pids_limit: i64,
    pub nano_cpus: i64,
    /// Parent cgroup (a systemd slice with the systemd cgroup driver) bounding all task
    /// containers together; `None` uses Docker's default.
    pub cgroup_parent: Option<String>,
}

impl ContainerConfig {
    fn validate(&self) -> Result<()> {
        if self.image.trim().is_empty() {
            bail!("container image must not be empty");
        }
        if self
            .cgroup_parent
            .as_deref()
            .is_some_and(|parent| parent.trim().is_empty() || parent.contains(char::is_whitespace))
        {
            bail!("cgroup parent must be a non-empty name without whitespace");
        }
        if self.memory_bytes < 0 || self.pids_limit < 0 || self.nano_cpus < 0 {
            bail!("container resource limits must not be negative");
        }
        Ok(())
    }
}

pub struct ContainerManager {
    docker: Docker,
    config: ContainerConfig,
    runner_id: String,
    store: StdMutex<Store>,
    lifecycle: Mutex<()>,
    failed: AtomicBool,
    shutting_down: AtomicBool,
    _lock: File,
}

pub struct ContainerLease {
    pub container_id: String,
    pub root_chat_id: i64,
    pub generation: i64,
    pub recreated: bool,
    pub reset_reason: Option<String>,
    manager: Arc<ContainerManager>,
    finished: bool,
    // The command currently running for this lease; set before its exec is created.
    active_exec: StdMutex<Option<String>>,
}

/// How an interrupted command was terminated.
pub enum ExecStop {
    /// Only the command's own processes were stopped; the workspace is intact.
    Stopped,
    /// The targeted stop failed, so the whole container was removed as a last resort.
    ContainerDestroyed(String),
}

impl ContainerLease {
    /// Acknowledge that execution has terminated before releasing its durable busy marker.
    /// Aborted futures deliberately do not call this method.
    pub fn finish(&mut self) -> Result<()> {
        self.finish_with_notice(true)
    }

    /// Release an unused allocation without claiming its reset warning was delivered.
    pub fn finish_without_notice(&mut self) -> Result<()> {
        self.finish_with_notice(false)
    }

    /// The command started by this lease whose termination is not yet confirmed.
    pub fn active_exec(&self) -> Option<String> {
        self.active_exec
            .lock()
            .map(|exec| exec.clone())
            .unwrap_or_default()
    }

    fn clear_exec(&self, exec_id: &str) {
        if let Ok(mut exec) = self.active_exec.lock() {
            if exec.as_deref() == Some(exec_id) {
                *exec = None;
            }
        }
    }

    fn finish_with_notice(&mut self, acknowledge_notice: bool) -> Result<()> {
        if self.finished {
            return Ok(());
        }
        let result = now_millis().and_then(|now| {
            self.manager.with_store(|store| {
                if acknowledge_notice {
                    store.release(self.root_chat_id, self.generation, now)
                } else {
                    store.release_without_notice(self.root_chat_id, self.generation, now)
                }
            })
        });
        if result.is_err() {
            self.manager.failed.store(true, Ordering::SeqCst);
        } else {
            self.finished = true;
        }
        result
    }
}

impl Drop for ContainerLease {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        let exec_id = self.active_exec.get_mut().ok().and_then(Option::take);
        let Some(exec_id) = exec_id else {
            // The aborted call had no command in flight, so no orphaned process can exist.
            if let Err(error) = self.finish_without_notice() {
                warn!(root_chat_id = self.root_chat_id, %error, "failed to release abandoned container lease; restart the runner after repairing storage");
            }
            return;
        };
        // A forced future abort does not stop docker exec. Stop exactly that command; its
        // durable exec record and busy marker stay until confirmed, so a restart can stop it
        // even if the runtime cannot run this cleanup.
        let Ok(runtime) = tokio::runtime::Handle::try_current() else {
            return;
        };
        let manager = Arc::clone(&self.manager);
        let root_chat_id = self.root_chat_id;
        let generation = self.generation;
        let container_id = self.container_id.clone();
        runtime.spawn(async move {
            match manager.stop_execs(&container_id, std::slice::from_ref(&exec_id)).await {
                Ok(()) => {
                    let released = manager.with_store(|store| {
                        store.exec_finished(&exec_id)?;
                        store.release_without_notice(root_chat_id, generation, now_millis()?)
                    });
                    if let Err(error) = released {
                        manager.failed.store(true, Ordering::SeqCst);
                        warn!(root_chat_id, %error, "failed to release abandoned container lease; restart the runner after repairing storage");
                    }
                }
                Err(stop_error) => {
                    warn!(root_chat_id, error = %format!("{stop_error:#}"), "cannot stop the processes of an abandoned call; removing its task container");
                    let _guard = manager.lifecycle.lock().await;
                    let result: Result<()> = async {
                        if let Some(row) = manager.with_store(|store| store.get(root_chat_id))? {
                            if row.generation == generation && row.status != "destroyed" {
                                manager.remove_record(&row, "call_aborted").await?;
                            }
                        }
                        Ok(())
                    }
                    .await;
                    if let Err(error) = result {
                        warn!(root_chat_id, %error, "abandoned task cleanup failed; the runner retries after restart");
                    }
                }
            }
        });
    }
}

impl ContainerManager {
    pub async fn open(
        docker: Docker,
        config: ContainerConfig,
        server_url: &str,
        token: &str,
    ) -> Result<Arc<Self>> {
        config.validate()?;
        std::fs::create_dir_all(&config.data_dir)
            .context("failed to create container state directory")?;
        let lock_path = config.data_dir.join("runner.lock");
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(&lock_path)
            .context("failed to open container runner lock")?;
        lock.try_lock_exclusive()
            .context("another container runner is using this data directory")?;
        let db_path = config.data_dir.join("containers.sqlite3");
        let store = Store::open(&db_path, server_url, token)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&db_path, std::fs::Permissions::from_mode(0o600))?;
        }
        let manager = Arc::new(Self {
            docker,
            config,
            runner_id: store.runner_id.clone(),
            store: StdMutex::new(store),
            lifecycle: Mutex::new(()),
            failed: AtomicBool::new(false),
            shutting_down: AtomicBool::new(false),
            _lock: lock,
        });
        manager
            .docker
            .ping()
            .await
            .context("Docker Engine is unavailable")?;
        manager.recover().await?;
        Ok(manager)
    }

    pub fn runner_id(&self) -> &str {
        &self.runner_id
    }

    pub fn docker(&self) -> &Docker {
        &self.docker
    }

    fn with_store<T>(&self, f: impl FnOnce(&mut Store) -> Result<T>) -> Result<T> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| anyhow!("container database lock is poisoned"))?;
        f(&mut store)
    }

    fn healthy(&self) -> Result<()> {
        if self.failed.load(Ordering::SeqCst) {
            bail!("container state storage failed; repair storage and restart the runner");
        }
        if self.shutting_down.load(Ordering::SeqCst) {
            bail!("container runner is shutting down");
        }
        Ok(())
    }

    pub async fn acquire(
        self: &Arc<Self>,
        root_chat_id: i64,
        user_id: i64,
    ) -> Result<ContainerLease> {
        if root_chat_id <= 0 || user_id <= 0 {
            bail!("a positive server-issued root_chat_id and user_id are required");
        }
        let mut resolved_image = None;
        loop {
            let _guard = self.lifecycle.lock().await;
            self.healthy()?;
            let previous = self.with_store(|store| store.get(root_chat_id))?;
            if let Some(row) = previous.as_ref() {
                if row.user_id != user_id {
                    bail!("workspace belongs to a different user");
                }
                match row.status.as_str() {
                    "ready" => match self.inspect_owned(row).await? {
                        Some(container) if running(&container) => return self.lease(row),
                        Some(_) => self.remove_record(row, "container_stopped").await?,
                        None => self.with_store(|store| {
                            store.destroyed(
                                root_chat_id,
                                row.generation,
                                "container_missing",
                                now_millis()?,
                            )
                        })?,
                    },
                    "creating" | "deleting" => {
                        let reason = row
                            .reset_reason
                            .as_deref()
                            .unwrap_or("interrupted_container_creation");
                        self.remove_record(row, reason).await?;
                    }
                    "destroyed" => {}
                    _ => bail!("invalid container lifecycle state"),
                }
            }
            if resolved_image.is_none() {
                // Pulling may take minutes; never block emergency deletion of another workspace.
                drop(_guard);
                resolved_image = Some(
                    tokio::time::timeout(Duration::from_secs(900), self.resolve_image())
                        .await
                        .context("Task image preparation timed out after 15 minutes")??,
                );
                continue;
            }
            let image_id = resolved_image
                .as_ref()
                .expect("image resolved before creation");
            self.maintain().await?;
            let row = self
                .with_store(|store| store.reserve_creation(root_chat_id, user_id, now_millis()?))?;
            let labels = HashMap::from([
                (RUNNER_LABEL.to_string(), self.runner_id.clone()),
                (ROOT_LABEL.to_string(), root_chat_id.to_string()),
                (GENERATION_LABEL.to_string(), row.generation.to_string()),
            ]);
            let memory = (self.config.memory_bytes > 0).then_some(self.config.memory_bytes);
            let created = self
                .docker
                .create_container(
                    Some(CreateContainerOptions {
                        name: row.container_name.clone(),
                        platform: None,
                    }),
                    Config {
                        image: Some(image_id.clone()),
                        entrypoint: Some(vec!["/bin/sh".to_string(), "-c".to_string()]),
                        cmd: Some(vec!["exec sleep infinity".to_string()]),
                        working_dir: Some("/workspace".to_string()),
                        user: Some("0:0".to_string()),
                        labels: Some(labels),
                        host_config: Some(HostConfig {
                            init: Some(true),
                            memory,
                            memory_swap: memory,
                            pids_limit: (self.config.pids_limit > 0)
                                .then_some(self.config.pids_limit),
                            nano_cpus: (self.config.nano_cpus > 0).then_some(self.config.nano_cpus),
                            cgroup_parent: self.config.cgroup_parent.clone(),
                            // Keep ordinary package installation working without raw network sockets.
                            cap_drop: Some(vec!["NET_RAW".to_string()]),
                            security_opt: Some(vec!["no-new-privileges:true".to_string()]),
                            log_config: Some(HostConfigLogConfig {
                                typ: Some("none".to_string()),
                                config: None,
                            }),
                            auto_remove: Some(false),
                            ..Default::default()
                        }),
                        ..Default::default()
                    },
                )
                .await
                .context("failed to create task container")?;
            // The durable name/generation is already sufficient to reconcile an interrupted start.
            self.docker
                .start_container(&created.id, None::<StartContainerOptions<String>>)
                .await
                .context("failed to start task container")?;
            self.with_store(|store| {
                store.ready(root_chat_id, row.generation, &created.id, image_id)
            })?;
            let ready = self
                .with_store(|store| store.get(root_chat_id))?
                .ok_or_else(|| anyhow!("created container record is missing"))?;
            info!(root_chat_id, generation = ready.generation, container_id = %created.id, "created task container");
            return self.lease(&ready);
        }
    }

    fn lease(self: &Arc<Self>, row: &ContainerRecord) -> Result<ContainerLease> {
        let row = self
            .with_store(|store| store.acquire(row.root_chat_id, row.generation, now_millis()?))?;
        Ok(ContainerLease {
            container_id: row
                .container_id
                .ok_or_else(|| anyhow!("ready container has no Docker id"))?,
            root_chat_id: row.root_chat_id,
            generation: row.generation,
            recreated: row.notice_pending,
            reset_reason: row.notice_pending.then_some(row.reset_reason).flatten(),
            manager: Arc::clone(self),
            finished: false,
            active_exec: StdMutex::new(None),
        })
    }

    /// Persist a new command for `lease` before its exec is created.
    pub fn begin_exec(&self, lease: &ContainerLease) -> Result<String> {
        let exec_id = process::new_exec_id();
        let persisted = self.with_store(|store| {
            store.exec_started(
                lease.root_chat_id,
                lease.generation,
                &exec_id,
                now_millis()?,
            )
        });
        if let Err(error) = persisted {
            self.failed.store(true, Ordering::SeqCst);
            return Err(error.context("failed to persist command start"));
        }
        let mut active = lease
            .active_exec
            .lock()
            .map_err(|_| anyhow!("container lease lock is poisoned"))?;
        *active = Some(exec_id.clone());
        Ok(exec_id)
    }

    /// Record that a command's process has exited on its own.
    pub fn end_exec(&self, lease: &ContainerLease, exec_id: &str) {
        lease.clear_exec(exec_id);
        if let Err(error) = self.with_store(|store| store.exec_finished(exec_id)) {
            self.failed.store(true, Ordering::SeqCst);
            warn!(root_chat_id = lease.root_chat_id, %error, "failed to record command completion; restart the runner after repairing storage");
        }
    }

    /// Stop exactly one interrupted command. Only if that cannot be confirmed is the whole
    /// container removed; an unconfirmed removal is an unknown execution outcome.
    pub async fn stop_exec(
        &self,
        lease: &ContainerLease,
        exec_id: &str,
        reason: &str,
    ) -> Result<ExecStop> {
        match self
            .stop_execs(&lease.container_id, &[exec_id.to_string()])
            .await
        {
            Ok(()) => {
                self.end_exec(lease, exec_id);
                Ok(ExecStop::Stopped)
            }
            Err(stop_error) => {
                let stop_error = format!("{stop_error:#}");
                warn!(root_chat_id = lease.root_chat_id, error = %stop_error, "targeted command stop failed; removing the task container");
                self.destroy(lease, reason).await.map_err(|error| {
                    anyhow!(ExecutionOutcomeUnknown(format!(
                        "Cannot stop the command ({stop_error}) or confirm emergency container removal; execution outcome is unknown. Administrator intervention may be required: {error:#}"
                    )))
                })?;
                lease.clear_exec(exec_id);
                Ok(ExecStop::ContainerDestroyed(stop_error))
            }
        }
    }

    /// Run the in-container helper that stops all processes of `exec_ids`.
    pub async fn stop_execs(&self, container_id: &str, exec_ids: &[String]) -> Result<()> {
        if exec_ids.is_empty() {
            return Ok(());
        }
        let command = process::stop_command(exec_ids)?;
        let run = async {
            let exec = self
                .docker
                .create_exec(
                    container_id,
                    CreateExecOptions {
                        attach_stdout: Some(true),
                        attach_stderr: Some(true),
                        tty: Some(false),
                        cmd: Some(command),
                        ..Default::default()
                    },
                )
                .await?;
            let StartExecResults::Attached { mut output, .. } =
                self.docker.start_exec(&exec.id, None).await?
            else {
                bail!("Docker exec unexpectedly detached");
            };
            let mut diagnostics = String::new();
            while let Some(chunk) = output.next().await {
                if diagnostics.len() < 4096 {
                    diagnostics.push_str(&String::from_utf8_lossy(&chunk?.into_bytes()));
                }
            }
            let status = self.docker.inspect_exec(&exec.id).await?;
            match status.exit_code {
                Some(0) => Ok(()),
                code => bail!(
                    "process stop helper exited with {}: {}",
                    code.map_or_else(|| "unknown status".to_string(), |code| code.to_string()),
                    diagnostics.trim()
                ),
            }
        };
        tokio::time::timeout(STOP_DEADLINE, run)
            .await
            .context("process stop helper timed out")?
    }

    pub async fn destroy(&self, lease: &ContainerLease, reason: &str) -> Result<()> {
        let _guard = self.lifecycle.lock().await;
        if let Some(row) = self.with_store(|store| store.get(lease.root_chat_id))? {
            if row.generation == lease.generation && row.status != "destroyed" {
                self.remove_record(&row, reason).await?;
            }
        }
        Ok(())
    }

    pub async fn shutdown(&self) -> Result<()> {
        self.shutting_down.store(true, Ordering::SeqCst);
        let _guard = self.lifecycle.lock().await;
        let rows = self.with_store(|store| store.records())?;
        for row in rows {
            match row.status.as_str() {
                "destroyed" => {}
                "ready" => {
                    // Stop orphaned commands, not the workspace: files and idle daemons survive.
                    let exec_ids = self.with_store(|store| {
                        store.unconfirmed_execs(row.root_chat_id, row.generation)
                    })?;
                    let Some(container_id) = row.container_id.as_deref() else {
                        continue;
                    };
                    match self.stop_execs(container_id, &exec_ids).await {
                        Ok(()) => self.with_store(|store| {
                            exec_ids.iter().try_for_each(|id| store.exec_finished(id))
                        })?,
                        Err(error) => {
                            warn!(root_chat_id = row.root_chat_id, error = %format!("{error:#}"), "cannot stop running commands at shutdown; removing the task container");
                            self.remove_record(&row, "runner_shutdown_during_call")
                                .await?;
                        }
                    }
                }
                _ => {
                    self.remove_record(&row, "runner_shutdown_during_lifecycle_change")
                        .await?
                }
            }
        }
        Ok(())
    }

    async fn recover(&self) -> Result<()> {
        let _guard = self.lifecycle.lock().await;
        for row in self.with_store(|store| store.records())? {
            if row.status == "destroyed" {
                continue;
            }
            let unconfirmed = row.status == "ready"
                && !self
                    .with_store(|store| store.unconfirmed_execs(row.root_chat_id, row.generation))?
                    .is_empty();
            if row.status == "ready" && (row.active_calls > 0 || unconfirmed) {
                self.recover_interrupted_calls(&row).await?;
            } else if row.status == "creating" {
                self.remove_record(&row, "runner_restarted_during_creation")
                    .await?;
            } else if row.status == "deleting" {
                let reason = row
                    .reset_reason
                    .as_deref()
                    .unwrap_or("interrupted_container_deletion");
                self.remove_record(&row, reason).await?;
            } else {
                match self.inspect_owned(&row).await? {
                    Some(container) if running(&container) => {}
                    Some(_) => self.remove_record(&row, "container_stopped").await?,
                    None => self.with_store(|store| {
                        store.destroyed(
                            row.root_chat_id,
                            row.generation,
                            "container_missing",
                            now_millis()?,
                        )
                    })?,
                }
            }
        }
        let known_ids: std::collections::HashSet<String> = self
            .with_store(|store| store.records())?
            .into_iter()
            .filter(|row| row.status != "destroyed")
            .filter_map(|row| row.container_id)
            .collect();
        for (id, _) in self.managed_sizes().await? {
            if !known_ids.contains(&id) {
                warn!(container_id = %id, runner_id = %self.runner_id, "untracked task container left untouched; inspect it manually before removal");
            }
        }
        Ok(())
    }

    /// Calls of a previous runner process cannot complete any more. Stop their commands but
    /// keep the workspace; remove it only if the commands cannot be stopped.
    async fn recover_interrupted_calls(&self, row: &ContainerRecord) -> Result<()> {
        let container = match self.inspect_owned(row).await? {
            Some(container) if running(&container) => container,
            Some(_) => return self.remove_record(row, "container_stopped").await,
            None => {
                return self.with_store(|store| {
                    store.destroyed(
                        row.root_chat_id,
                        row.generation,
                        "container_missing",
                        now_millis()?,
                    )
                })
            }
        };
        let container_id = container
            .id
            .ok_or_else(|| anyhow!("Docker inspect response has no container id"))?;
        let exec_ids =
            self.with_store(|store| store.unconfirmed_execs(row.root_chat_id, row.generation))?;
        match self.stop_execs(&container_id, &exec_ids).await {
            Ok(()) => {
                self.with_store(|store| {
                    store.interrupted_calls_stopped(row.root_chat_id, row.generation)
                })?;
                info!(
                    root_chat_id = row.root_chat_id,
                    generation = row.generation,
                    stopped_commands = exec_ids.len(),
                    "stopped commands interrupted by a runner restart; workspace kept"
                );
                Ok(())
            }
            Err(error) => {
                warn!(root_chat_id = row.root_chat_id, error = %format!("{error:#}"), "cannot stop commands interrupted by a runner restart; removing the task container");
                self.remove_record(row, "runner_restarted_during_call")
                    .await
            }
        }
    }

    async fn inspect_owned(
        &self,
        row: &ContainerRecord,
    ) -> Result<Option<ContainerInspectResponse>> {
        let reference = row.container_id.as_deref().unwrap_or(&row.container_name);
        match self
            .docker
            .inspect_container(reference, None::<InspectContainerOptions>)
            .await
        {
            Ok(container) => {
                let labels = container
                    .config
                    .as_ref()
                    .and_then(|config| config.labels.as_ref());
                let expected_root = row.root_chat_id.to_string();
                let expected_generation = row.generation.to_string();
                let owned = labels.is_some_and(|labels| {
                    labels.get(RUNNER_LABEL) == Some(&self.runner_id)
                        && labels.get(ROOT_LABEL) == Some(&expected_root)
                        && labels.get(GENERATION_LABEL) == Some(&expected_generation)
                });
                if !owned {
                    bail!("Docker container {reference} does not match this runner's durable ownership labels; refusing to use or delete it");
                }
                Ok(Some(container))
            }
            Err(error) if not_found(&error) => Ok(None),
            Err(error) => Err(error)
                .context("failed to inspect task container; state has not been treated as lost"),
        }
    }

    async fn remove_record(&self, row: &ContainerRecord, reason: &str) -> Result<()> {
        // Inspect first: the database must never authorize removing a foreign Docker object.
        let container = self.inspect_owned(row).await?;
        self.with_store(|store| store.deleting(row.root_chat_id, row.generation, reason))?;
        if let Some(container) = container {
            let id = container
                .id
                .ok_or_else(|| anyhow!("Docker inspect response has no container id"))?;
            match self
                .docker
                .remove_container(
                    &id,
                    Some(RemoveContainerOptions {
                        force: true,
                        v: true,
                        ..Default::default()
                    }),
                )
                .await
            {
                Ok(()) => {}
                Err(error) if not_found(&error) => {}
                Err(error) => {
                    return Err(error)
                        .context("failed to remove task container; deletion will be retried")
                }
            }
        }
        self.with_store(|store| {
            store.destroyed(row.root_chat_id, row.generation, reason, now_millis()?)
        })?;
        info!(
            root_chat_id = row.root_chat_id,
            generation = row.generation,
            reason,
            "task container destroyed"
        );
        Ok(())
    }

    async fn resolve_image(&self) -> Result<String> {
        let image = match self.docker.inspect_image(&self.config.image).await {
            Ok(image) => image,
            Err(error) if not_found(&error) => {
                info!(image = %self.config.image, "pulling task container image");
                let mut pull = self.docker.create_image(
                    Some(CreateImageOptions {
                        from_image: self.config.image.clone(),
                        ..Default::default()
                    }),
                    None,
                    None,
                );
                while let Some(update) = pull
                    .try_next()
                    .await
                    .context("failed to pull task container image")?
                {
                    if let Some(error) = update.error {
                        bail!("failed to pull task container image: {error}");
                    }
                }
                self.docker
                    .inspect_image(&self.config.image)
                    .await
                    .context("pulled task image cannot be inspected")?
            }
            Err(error) => return Err(error).context("failed to inspect task container image"),
        };
        if image
            .config
            .as_ref()
            .and_then(|config| config.volumes.as_ref())
            .is_some_and(|volumes| !volumes.is_empty())
        {
            bail!("task images must not declare VOLUME paths: use the container writable layer so disk accounting and cleanup remain reliable");
        }
        image
            .id
            .filter(|id| !id.is_empty())
            .ok_or_else(|| anyhow!("Docker image has no immutable image id"))
    }

    async fn managed_sizes(&self) -> Result<HashMap<String, u64>> {
        let filters = HashMap::from([(
            "label".to_string(),
            vec![format!("{RUNNER_LABEL}={}", self.runner_id)],
        )]);
        let containers = self
            .docker
            .list_containers(Some(ListContainersOptions::<String> {
                all: true,
                size: true,
                filters,
                ..Default::default()
            }))
            .await
            .context("failed to measure managed task containers")?;
        Ok(containers.into_iter().filter_map(|container| {
            container.id.map(|id| {
                if container.size_rw.is_none() {
                    warn!(container_id = %id, "Docker did not report writable-layer size; disk target is advisory");
                }
                (id, container.size_rw.unwrap_or(0).max(0) as u64)
            })
        }).collect())
    }

    async fn maintain(&self) -> Result<()> {
        if self.config.max_containers == 0 && self.config.max_disk_bytes == 0 {
            return Ok(());
        }
        let mut sizes = self.managed_sizes().await?;
        let mut total_bytes = sizes
            .values()
            .fold(0_u64, |sum, size| sum.saturating_add(*size));
        let now = now_millis()?;
        for row in self.with_store(|store| store.records())? {
            if !over_target(sizes.len(), total_bytes, &self.config) {
                break;
            }
            if !eviction_eligible(&row, now, self.config.guaranteed_ttl) {
                continue;
            }
            let bytes = row
                .container_id
                .as_ref()
                .and_then(|id| sizes.get(id))
                .copied();
            self.remove_record(&row, "idle_eviction").await?;
            if let Some(id) = row.container_id {
                sizes.remove(&id);
            }
            total_bytes = total_bytes.saturating_sub(bytes.unwrap_or(0));
        }
        if over_target(sizes.len(), total_bytes, &self.config) {
            info!(containers = sizes.len(), writable_bytes = total_bytes,
                "soft retention target exceeded; all remaining containers are busy, protected by TTL, or untracked; allowing creation");
        }
        Ok(())
    }
}

fn running(container: &ContainerInspectResponse) -> bool {
    container.state.as_ref().and_then(|state| state.running) == Some(true)
}

fn not_found(error: &DockerError) -> bool {
    matches!(
        error,
        DockerError::DockerResponseServerError {
            status_code: 404,
            ..
        }
    )
}

fn over_target(existing_count: usize, writable_bytes: u64, config: &ContainerConfig) -> bool {
    (config.max_containers > 0 && existing_count >= config.max_containers)
        || (config.max_disk_bytes > 0 && writable_bytes > config.max_disk_bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(data_dir: PathBuf) -> ContainerConfig {
        ContainerConfig {
            data_dir,
            image: std::env::var("OUTLET_TEST_IMAGE").unwrap_or_else(|_| "alpine:3.21".to_string()),
            max_containers: 1,
            max_disk_bytes: 1_000_000_000,
            guaranteed_ttl: Duration::ZERO,
            memory_bytes: 128 * 1024 * 1024,
            pids_limit: 64,
            nano_cpus: 1_000_000_000,
            cgroup_parent: std::env::var("OUTLET_TEST_CGROUP_PARENT").ok(),
        }
    }

    #[test]
    fn thresholds_are_advisory_and_allow_disable() {
        let mut config = config(PathBuf::from("unused"));
        assert!(!over_target(0, 0, &config));
        assert!(over_target(1, 0, &config));
        assert!(over_target(0, config.max_disk_bytes + 1, &config));
        config.max_containers = 0;
        config.max_disk_bytes = 0;
        assert!(!over_target(usize::MAX, u64::MAX, &config));
    }

    #[test]
    fn only_actual_docker_not_found_is_state_loss() {
        assert!(not_found(&DockerError::DockerResponseServerError {
            status_code: 404,
            message: "missing".to_string()
        }));
        assert!(!not_found(&DockerError::DockerResponseServerError {
            status_code: 500,
            message: "daemon failed".to_string()
        }));
    }

    #[test]
    fn abandoned_lease_releases_idle_allocation_but_keeps_running_command_for_recovery() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config(dir.path().to_path_buf());
        let mut store = Store::open(&dir.path().join("containers.sqlite3"), "s", "t").unwrap();
        let row = store.reserve_creation(1, 7, 10).unwrap();
        store
            .ready(1, row.generation, "fake-container", "fake-image")
            .unwrap();
        let manager = Arc::new(ContainerManager {
            docker: Docker::connect_with_http(
                "http://127.0.0.1:1",
                1,
                bollard::API_DEFAULT_VERSION,
            )
            .unwrap(),
            runner_id: store.runner_id.clone(),
            config: cfg,
            store: StdMutex::new(store),
            lifecycle: Mutex::new(()),
            failed: AtomicBool::new(false),
            shutting_down: AtomicBool::new(false),
            _lock: File::create(dir.path().join("runner.lock")).unwrap(),
        });
        let row = manager.with_store(|store| store.get(1)).unwrap().unwrap();
        let mut completed = manager.lease(&row).unwrap();
        let exec_id = manager.begin_exec(&completed).unwrap();
        manager.end_exec(&completed, &exec_id);
        completed.finish().unwrap();
        drop(completed);
        let row = manager.with_store(|store| store.get(1)).unwrap().unwrap();
        assert_eq!((row.active_calls, row.status.as_str()), (0, "ready"));

        // Aborted outside a command: nothing can be orphaned, so the allocation is released.
        drop(manager.lease(&row).unwrap());
        let row = manager.with_store(|store| store.get(1)).unwrap().unwrap();
        assert_eq!((row.active_calls, row.status.as_str()), (0, "ready"));

        // Aborted during a command without a runtime to stop it: the busy marker and the
        // durable command record remain for restart recovery; the workspace is not deleted.
        let running = manager.lease(&row).unwrap();
        let exec_id = manager.begin_exec(&running).unwrap();
        drop(running);
        let row = manager.with_store(|store| store.get(1)).unwrap().unwrap();
        assert_eq!((row.active_calls, row.status.as_str()), (1, "ready"));
        assert_eq!(
            manager
                .with_store(|store| store.unconfirmed_execs(1, row.generation))
                .unwrap(),
            vec![exec_id]
        );
    }

    fn test_docker() -> Docker {
        #[cfg(unix)]
        if let Ok(socket) = std::env::var("OUTLET_TEST_DOCKER_SOCKET") {
            return Docker::connect_with_unix(&socket, 120, bollard::API_DEFAULT_VERSION).unwrap();
        }
        Docker::connect_with_local_defaults().unwrap()
    }

    async fn cleanup(manager: &ContainerManager) {
        if let Ok(containers) = manager.managed_sizes().await {
            for id in containers.keys() {
                let _ = manager
                    .docker
                    .remove_container(
                        id,
                        Some(RemoveContainerOptions {
                            force: true,
                            v: true,
                            ..Default::default()
                        }),
                    )
                    .await;
            }
        }
    }

    #[tokio::test]
    #[ignore = "requires a local Docker Engine; uses only a temporary labelled namespace"]
    async fn docker_busy_lru_missing_and_restart_lifecycle() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = config(dir.path().to_path_buf());
        let docker = test_docker();
        let manager = ContainerManager::open(docker.clone(), cfg.clone(), "http://test", "test")
            .await
            .unwrap();
        let result: Result<()> = async {
            let mut first = manager.acquire(1, 7).await?;
            let first_id = first.container_id.clone();
            let mut second = manager.acquire(2, 7).await?;
            let second_id = second.container_id.clone();
            anyhow::ensure!(manager.managed_sizes().await?.len() == 2, "busy workspaces must exceed soft target");
            second.finish()?;
            drop(second);
            let mut third = manager.acquire(3, 7).await?;
            anyhow::ensure!(manager.docker.inspect_container(&first_id, None::<InspectContainerOptions>).await.is_ok());
            anyhow::ensure!(matches!(manager.docker.inspect_container(&second_id, None::<InspectContainerOptions>).await, Err(e) if not_found(&e)));
            manager.docker.remove_container(&third.container_id, Some(RemoveContainerOptions { force: true, ..Default::default() })).await?;
            third.finish()?;
            drop(third);
            let mut replacement = manager.acquire(3, 7).await?;
            anyhow::ensure!(replacement.recreated && replacement.generation == 2);
            anyhow::ensure!(replacement.reset_reason.as_deref() == Some("container_missing"));
            anyhow::ensure!(manager.acquire(3, 8).await.is_err());
            replacement.finish()?;
            drop(replacement);
            first.finish()?;
            drop(first);
            Ok(())
        }.await;
        cleanup(&manager).await;
        result.unwrap();
    }

    async fn exec_output(docker: &Docker, container: &str, script: &str) -> Result<String> {
        let exec = docker
            .create_exec(
                container,
                CreateExecOptions {
                    attach_stdout: Some(true),
                    cmd: Some(vec![
                        "/bin/sh".to_string(),
                        "-c".to_string(),
                        script.to_string(),
                    ]),
                    ..Default::default()
                },
            )
            .await?;
        let StartExecResults::Attached { mut output, .. } =
            docker.start_exec(&exec.id, None).await?
        else {
            bail!("exec detached");
        };
        let mut text = String::new();
        while let Some(chunk) = output.next().await {
            text.push_str(&String::from_utf8_lossy(&chunk?.into_bytes()));
        }
        Ok(text)
    }

    async fn count_processes(docker: &Docker, container: &str, needle: &str) -> Result<usize> {
        let table = exec_output(
            docker,
            container,
            r#"for p in /proc/[0-9]*; do tr '\0' ' ' < "$p/cmdline" 2>/dev/null; echo; done"#,
        )
        .await?;
        Ok(table.lines().filter(|line| line.contains(needle)).count())
    }

    #[tokio::test]
    #[ignore = "requires a local Docker Engine; uses only a temporary labelled namespace"]
    async fn docker_restart_stops_orphaned_commands_and_keeps_workspaces() {
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = config(dir.path().to_path_buf());
        cfg.max_containers = 10;
        let docker = test_docker();
        let manager = ContainerManager::open(docker.clone(), cfg.clone(), "http://test", "test")
            .await
            .unwrap();
        let mut first = manager.acquire(1, 7).await.unwrap();
        let first_id = first.container_id.clone();
        let runner_id = manager.runner_id().to_string();
        first.finish().unwrap();
        drop(first);
        let mut second = manager.acquire(2, 7).await.unwrap();
        let second_id = second.container_id.clone();
        second.finish().unwrap();
        drop(second);
        // Simulate a crash during a call: a busy marker, a durable command record and its
        // still-running process tree, with no lease left to clean up.
        let orphan = process::new_exec_id();
        manager
            .with_store(|store| {
                store.acquire(2, 1, now_millis()?)?;
                store.exec_started(2, 1, &orphan, now_millis()?)
            })
            .unwrap();
        let exec = docker
            .create_exec(
                &second_id,
                CreateExecOptions {
                    cmd: Some(process::wrap_command(vec![
                        "/bin/sh".into(),
                        "-c".into(),
                        "printf kept > /workspace/file; nohup sleep 3171 >/dev/null 2>&1 & sleep 3170".into(),
                    ])),
                    env: Some(vec![format!("{}={orphan}", process::EXEC_ID_ENV)]),
                    ..Default::default()
                },
            )
            .await
            .unwrap();
        docker
            .start_exec(
                &exec.id,
                Some(bollard::exec::StartExecOptions {
                    detach: true,
                    ..Default::default()
                }),
            )
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_secs(1)).await;
        drop(manager);
        let manager = ContainerManager::open(docker.clone(), cfg, "http://test", "test")
            .await
            .unwrap();
        let result: Result<()> = async {
            anyhow::ensure!(manager.runner_id() == runner_id);
            let mut idle = manager.acquire(1, 7).await?;
            anyhow::ensure!(idle.container_id == first_id && !idle.recreated);
            let mut interrupted = manager.acquire(2, 7).await?;
            anyhow::ensure!(
                interrupted.container_id == second_id && !interrupted.recreated,
                "restart recovery replaced a workspace whose commands could be stopped"
            );
            anyhow::ensure!(count_processes(&docker, &second_id, "sleep 317").await? == 0);
            anyhow::ensure!(
                exec_output(&docker, &second_id, "cat /workspace/file").await? == "kept"
            );
            let row = manager.with_store(|store| store.get(2))?.context("row")?;
            anyhow::ensure!(
                row.active_calls == 1,
                "recovery must reset the stale busy marker"
            );
            anyhow::ensure!(manager
                .with_store(|store| store.unconfirmed_execs(2, 1))?
                .is_empty());
            idle.finish()?;
            interrupted.finish()?;
            Ok(())
        }
        .await;
        cleanup(&manager).await;
        result.unwrap();
    }
}

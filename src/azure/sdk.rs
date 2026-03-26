//! Azure Blob Storage SDK client for batch mode
//!
//! Provides direct Azure Blob Storage access using the official Azure SDK,
//! bypassing BlobFuse2 FUSE mounts. Used in batch mode to download inputs,
//! upload outputs, and move blobs between containers.
//!
//! Authentication (checked in priority order):
//! 1. `AZURE_STORAGE_SAS_TOKEN` → SAS token appended to endpoint URL (no credential needed)
//! 2. `AZURE_USE_MANAGED_IDENTITY=true` → Managed Identity (Azure VMs, ACI, AKS)
//! 3. Default → Developer Tools (Azure CLI `az login`, Azure Developer CLI)

use anyhow::{bail, Context, Result};
use azure_core::{
    credentials::TokenCredential,
    http::RequestContent,
};
use azure_identity::{
    DeveloperToolsCredential, ManagedIdentityCredential, ManagedIdentityCredentialOptions,
    UserAssignedId,
};
use azure_storage_blob::{
    models::BlobContainerClientListBlobsOptions,
    BlobClient, BlobContainerClient,
};
use futures::StreamExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::fs;
use tracing::{debug, info, instrument, warn};

/// Azure Blob Storage client for SDK-based operations
///
/// Supports three authentication methods:
/// - **SAS token**: Appended to the endpoint URL, no credential object needed
/// - **Managed Identity**: For Azure-hosted workloads (VMs, ACI, AKS)
/// - **Developer Tools**: Azure CLI / Azure Developer CLI for local development
pub struct BlobStorageClient {
    endpoint: String,
    credential: Option<Arc<dyn TokenCredential>>,
    pub container_input: String,
    pub container_output: String,
    pub container_processed: String,
    pub container_error: String,
}

impl std::fmt::Debug for BlobStorageClient {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("BlobStorageClient")
            .field("endpoint", &self.endpoint)
            .field("auth", &if self.credential.is_some() { "token" } else { "sas" })
            .field("container_input", &self.container_input)
            .field("container_output", &self.container_output)
            .field("container_processed", &self.container_processed)
            .field("container_error", &self.container_error)
            .finish_non_exhaustive()
    }
}

impl BlobStorageClient {
    /// Create a new BlobStorageClient from environment variables
    ///
    /// Required: `AZURE_STORAGE_ACCOUNT`
    ///
    /// Auth selection (checked in priority order):
    /// 1. `AZURE_STORAGE_SAS_TOKEN` → SAS token (appended to endpoint URL)
    /// 2. `AZURE_USE_MANAGED_IDENTITY=true` → Managed Identity
    /// 3. Default → Developer Tools (Azure CLI credentials)
    ///
    /// Optional container name overrides (defaults shown):
    /// - `AZURE_BLOB_CONTAINER_INPUT` (default: "input")
    /// - `AZURE_BLOB_CONTAINER_OUTPUT` (default: "output")
    /// - `AZURE_BLOB_CONTAINER_PROCESSED` (default: "processed")
    /// - `AZURE_BLOB_CONTAINER_ERROR` (default: "error")
    #[instrument(skip_all)]
    pub fn from_env() -> Result<Self> {
        let account = std::env::var("AZURE_STORAGE_ACCOUNT")
            .context("AZURE_STORAGE_ACCOUNT is required for batch mode")?;

        if account.is_empty() {
            bail!("AZURE_STORAGE_ACCOUNT is set but empty");
        }

        // Custom endpoint for Azurite or sovereign clouds
        let custom_endpoint = std::env::var("AZURE_STORAGE_ENDPOINT").ok().filter(|s| !s.is_empty());

        let sas_token = std::env::var("AZURE_STORAGE_SAS_TOKEN").ok().filter(|s| !s.is_empty());

        let use_msi = std::env::var("AZURE_USE_MANAGED_IDENTITY")
            .unwrap_or_default()
            .to_lowercase()
            == "true";

        let base_endpoint = custom_endpoint
            .clone()
            .unwrap_or_else(|| format!("https://{}.blob.core.windows.net/", account));

        let (endpoint, credential, auth_method): (String, Option<Arc<dyn TokenCredential>>, &str) =
            if let Some(ref sas) = sas_token {
                // SAS token auth: append token to endpoint URL, no credential needed
                let sas_query = sas.strip_prefix('?').unwrap_or(sas);
                let sep = if base_endpoint.contains('?') { "&" } else { "?" };
                let endpoint = format!("{}{}{}", base_endpoint, sep, sas_query);
                info!("Using SAS token for Azure Blob Storage SDK");
                (endpoint, None, "sas_token")
            } else if use_msi {
                info!("Using Managed Identity credential for Azure Blob Storage SDK");
                // Support user-assigned managed identity via AZURE_CLIENT_ID
                let mi_options = std::env::var("AZURE_CLIENT_ID")
                    .ok()
                    .filter(|id| !id.is_empty())
                    .map(|client_id| {
                        info!(client_id = %client_id, "Using user-assigned managed identity");
                        ManagedIdentityCredentialOptions {
                            user_assigned_id: Some(UserAssignedId::ClientId(client_id)),
                            ..Default::default()
                        }
                    });
                let cred = ManagedIdentityCredential::new(mi_options)
                    .context("Failed to create ManagedIdentityCredential")?;
                (base_endpoint, Some(cred), "managed_identity")
            } else {
                info!("Using Developer Tools credential (Azure CLI) for Azure Blob Storage SDK");
                let cred = DeveloperToolsCredential::new(None)
                    .context("Failed to create DeveloperToolsCredential")?;
                (base_endpoint, Some(cred), "developer_tools")
            };

        let container_input = std::env::var("AZURE_BLOB_CONTAINER_INPUT")
            .unwrap_or_else(|_| "input".to_string());
        let container_output = std::env::var("AZURE_BLOB_CONTAINER_OUTPUT")
            .unwrap_or_else(|_| "output".to_string());
        let container_processed = std::env::var("AZURE_BLOB_CONTAINER_PROCESSED")
            .unwrap_or_else(|_| "processed".to_string());
        let container_error = std::env::var("AZURE_BLOB_CONTAINER_ERROR")
            .unwrap_or_else(|_| "error".to_string());

        info!(
            account = %account,
            endpoint = %endpoint,
            container_input = %container_input,
            container_output = %container_output,
            auth = auth_method,
            "Azure Blob Storage SDK client initialized"
        );

        Ok(Self {
            endpoint,
            credential,
            container_input,
            container_output,
            container_processed,
            container_error,
        })
    }

    /// Get a `BlobContainerClient` for the specified container
    fn container_client(&self, container: &str) -> Result<BlobContainerClient> {
        BlobContainerClient::new(
            &self.endpoint,
            container,
            self.credential.clone(),
            None,
        )
        .context("Failed to create BlobContainerClient")
    }

    /// Get a `BlobClient` for a specific blob in a container
    fn blob_client(&self, container: &str, blob_name: &str) -> Result<BlobClient> {
        BlobClient::new(
            &self.endpoint,
            container,
            blob_name,
            self.credential.clone(),
            None,
        )
        .context("Failed to create BlobClient")
    }

    /// List all blobs in a container matching a given prefix
    #[instrument(skip(self), fields(container = %container, prefix = %prefix))]
    pub async fn list_blobs(&self, container: &str, prefix: &str) -> Result<Vec<String>> {
        let container_client = self.container_client(container)?;
        let mut blob_names = Vec::new();

        let options = BlobContainerClientListBlobsOptions {
            prefix: Some(prefix.to_string()),
            ..Default::default()
        };

        let mut pager = container_client
            .list_blobs(Some(options))
            .context("Failed to create blob list pager")?;

        // Pager implements Stream<Item = Result<BlobItem>>
        while let Some(item_result) = pager.next().await {
            let item = item_result
                .map_err(|e| anyhow::anyhow!("Failed to list blobs: {}", e))?;
            if let Some(ref name) = item.name {
                if let Some(ref content) = name.content {
                    blob_names.push(content.clone());
                }
            }
        }

        info!(count = blob_names.len(), "Listed blobs with prefix");
        Ok(blob_names)
    }

    /// Download a blob to a local file path
    #[instrument(skip(self), fields(container = %container, blob = %blob_name))]
    pub async fn download_blob(
        &self,
        container: &str,
        blob_name: &str,
        local_path: &Path,
    ) -> Result<()> {
        if let Some(parent) = local_path.parent() {
            fs::create_dir_all(parent)
                .await
                .with_context(|| format!("Failed to create directory: {}", parent.display()))?;
        }

        let blob_client = self.blob_client(container, blob_name)?;

        let response = blob_client
            .download(None)
            .await
            .with_context(|| format!("Failed to download blob: {}", blob_name))?;

        let data = response
            .into_body()
            .collect()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to read blob stream: {}", e))?;

        fs::write(local_path, &data)
            .await
            .with_context(|| format!("Failed to write to: {}", local_path.display()))?;

        debug!(
            size_bytes = data.len(),
            path = %local_path.display(),
            "Downloaded blob"
        );
        Ok(())
    }

    /// Download all blobs matching a prefix to a local directory
    ///
    /// Preserves the blob path structure relative to the prefix.
    /// Returns the list of local file paths that were downloaded.
    #[instrument(skip(self), fields(container = %container, prefix = %prefix))]
    pub async fn download_prefix(
        &self,
        container: &str,
        prefix: &str,
        local_dir: &Path,
    ) -> Result<Vec<PathBuf>> {
        let blob_names = self.list_blobs(container, prefix).await?;

        if blob_names.is_empty() {
            bail!(
                "No blobs found in container '{}' with prefix '{}'",
                container,
                prefix
            );
        }

        let mut local_paths = Vec::with_capacity(blob_names.len());

        for blob_name in &blob_names {
            let relative = blob_name.strip_prefix(prefix).unwrap_or(blob_name);
            let local_path = local_dir.join(relative);

            self.download_blob(container, blob_name, &local_path)
                .await?;
            local_paths.push(local_path);
        }

        info!(
            count = local_paths.len(),
            dir = %local_dir.display(),
            "Downloaded all blobs"
        );
        Ok(local_paths)
    }

    /// Upload a local file to a blob
    #[instrument(skip(self), fields(container = %container, blob = %blob_name))]
    pub async fn upload_blob(
        &self,
        container: &str,
        blob_name: &str,
        local_path: &Path,
    ) -> Result<()> {
        let data = fs::read(local_path)
            .await
            .with_context(|| format!("Failed to read file: {}", local_path.display()))?;

        let content_length =
            u64::try_from(data.len()).context("File size exceeds u64")?;

        let blob_client = self.blob_client(container, blob_name)?;

        blob_client
            .upload(RequestContent::from(data), true, content_length, None)
            .await
            .with_context(|| format!("Failed to upload blob: {}", blob_name))?;

        debug!(
            size_bytes = content_length,
            path = %local_path.display(),
            "Uploaded blob"
        );
        Ok(())
    }

    /// Upload all files from a local directory to a blob container with a prefix
    #[instrument(skip(self), fields(container = %container, prefix = %prefix))]
    pub async fn upload_directory(
        &self,
        container: &str,
        prefix: &str,
        local_dir: &Path,
    ) -> Result<Vec<String>> {
        let mut uploaded = Vec::new();

        let mut entries = fs::read_dir(local_dir)
            .await
            .with_context(|| format!("Failed to read directory: {}", local_dir.display()))?;

        while let Some(entry) = entries.next_entry().await? {
            let path = entry.path();
            if path.is_file() {
                let file_name = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .context("Invalid file name")?;

                let blob_name = if prefix.is_empty() {
                    file_name.to_string()
                } else {
                    format!("{}{}", prefix, file_name)
                };

                self.upload_blob(container, &blob_name, &path).await?;
                uploaded.push(blob_name);
            }
        }

        info!(count = uploaded.len(), "Uploaded directory contents");
        Ok(uploaded)
    }

    /// Copy a blob between containers via download + upload
    #[instrument(skip(self))]
    pub async fn copy_blob(
        &self,
        src_container: &str,
        src_blob: &str,
        dst_container: &str,
        dst_blob: &str,
    ) -> Result<()> {
        let src_client = self.blob_client(src_container, src_blob)?;
        let response = src_client
            .download(None)
            .await
            .with_context(|| format!("Failed to download {}/{}", src_container, src_blob))?;

        let data = response
            .into_body()
            .collect()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to read blob for copy: {}", e))?;

        let content_length = u64::try_from(data.len()).context("Blob size exceeds u64")?;
        let dst_client = self.blob_client(dst_container, dst_blob)?;
        dst_client
            .upload(RequestContent::from(data.to_vec()), true, content_length, None)
            .await
            .with_context(|| format!("Failed to upload to {}/{}", dst_container, dst_blob))?;

        debug!(
            src = format!("{}/{}", src_container, src_blob),
            dst = format!("{}/{}", dst_container, dst_blob),
            "Copied blob"
        );
        Ok(())
    }

    /// Delete a blob from a container
    #[instrument(skip(self))]
    pub async fn delete_blob(&self, container: &str, blob_name: &str) -> Result<()> {
        let blob_client = self.blob_client(container, blob_name)?;

        blob_client
            .delete(None)
            .await
            .with_context(|| format!("Failed to delete blob: {}/{}", container, blob_name))?;

        debug!(container = %container, blob = %blob_name, "Deleted blob");
        Ok(())
    }

    /// Move blobs matching a prefix from one container to another
    ///
    /// Copies all matching blobs, then deletes the sources.
    #[instrument(skip(self))]
    pub async fn move_blobs(
        &self,
        src_container: &str,
        prefix: &str,
        dst_container: &str,
    ) -> Result<()> {
        let blob_names = self.list_blobs(src_container, prefix).await?;

        for blob_name in &blob_names {
            self.copy_blob(src_container, blob_name, dst_container, blob_name)
                .await?;
        }

        // Delete sources only after all copies succeed
        for blob_name in &blob_names {
            if let Err(e) = self.delete_blob(src_container, blob_name).await {
                warn!(
                    blob = %blob_name,
                    error = %e,
                    "Failed to delete source blob after copy (non-fatal)"
                );
            }
        }

        info!(
            count = blob_names.len(),
            src = %src_container,
            dst = %dst_container,
            "Moved blobs between containers"
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_from_env_missing_account() {
        std::env::remove_var("AZURE_STORAGE_ACCOUNT");
        let result = BlobStorageClient::from_env();
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("AZURE_STORAGE_ACCOUNT"));
    }
}

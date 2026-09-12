//! FFmpeg-backed [`MediaProcessor`].
//!
//! Shells out to the `ffmpeg`/`ffprobe` binaries (via `tokio::process`) to inspect media and
//! extract normalized mono audio for ASR. If the tools aren't installed, calls return
//! [`MediaError::ToolUnavailable`] rather than failing opaquely. This is intentionally thin — no
//! media framework, just the extraction the pipeline needs.

use std::path::Path;

use async_trait::async_trait;
use tokio::process::Command;

use super::{ExtractOptions, MediaError, MediaInfo, MediaProcessor, PreparedAudio};

/// Media processing via the system `ffmpeg`/`ffprobe` binaries.
#[derive(Debug, Clone)]
pub struct FfmpegMediaProcessor {
    ffmpeg_bin: String,
    ffprobe_bin: String,
}

impl Default for FfmpegMediaProcessor {
    fn default() -> Self {
        Self {
            ffmpeg_bin: "ffmpeg".to_string(),
            ffprobe_bin: "ffprobe".to_string(),
        }
    }
}

impl FfmpegMediaProcessor {
    pub fn new() -> Self {
        Self::default()
    }
}

#[async_trait]
impl MediaProcessor for FfmpegMediaProcessor {
    async fn probe(&self, input: &Path) -> Result<MediaInfo, MediaError> {
        if !input.exists() {
            return Err(MediaError::InputNotFound(input.to_path_buf()));
        }
        let output = Command::new(&self.ffprobe_bin)
            .args([
                "-v",
                "error",
                "-show_entries",
                "format=duration",
                "-of",
                "default=noprint_wrappers=1:nokey=1",
            ])
            .arg(input)
            .output()
            .await
            .map_err(|e| MediaError::ToolUnavailable(format!("{}: {e}", self.ffprobe_bin)))?;

        if !output.status.success() {
            return Err(MediaError::Failed(
                String::from_utf8_lossy(&output.stderr).into_owned(),
            ));
        }
        let duration = String::from_utf8_lossy(&output.stdout)
            .trim()
            .parse::<f64>()
            .ok();
        Ok(MediaInfo {
            duration_seconds: duration,
            has_audio: true,
        })
    }

    async fn extract_audio(
        &self,
        input: &Path,
        out_dir: &Path,
        options: &ExtractOptions,
    ) -> Result<PreparedAudio, MediaError> {
        if !input.exists() {
            return Err(MediaError::InputNotFound(input.to_path_buf()));
        }
        tokio::fs::create_dir_all(out_dir)
            .await
            .map_err(|e| MediaError::Failed(e.to_string()))?;
        let out_path = out_dir.join("audio.wav");

        let status = Command::new(&self.ffmpeg_bin)
            .arg("-y")
            .arg("-i")
            .arg(input)
            .args(["-ac", &options.channels.to_string()])
            .args(["-ar", &options.sample_rate.to_string()])
            .args(["-vn", "-f", "wav"])
            .arg(&out_path)
            .status()
            .await
            .map_err(|e| MediaError::ToolUnavailable(format!("{}: {e}", self.ffmpeg_bin)))?;

        if !status.success() {
            return Err(MediaError::Failed(format!("ffmpeg exited with {status}")));
        }
        Ok(PreparedAudio {
            path: out_path,
            sample_rate: options.sample_rate,
            channels: options.channels,
        })
    }
}

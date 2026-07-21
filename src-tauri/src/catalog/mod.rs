//! The bundled, offline model catalog.
//!
//! `catalog.json` is generated at build time by `scripts/gen_catalog.py` from the
//! `handy-computer` Hugging Face org (card `transcribe_cpp` capabilities +
//! benchmarks, a GGUF header probe for name/params, and local curation for the
//! recommended set). It is compiled into the binary so Handy ships a complete
//! model list with zero network access.
//!
//! Each entry is normalised into a [`ModelDescriptor`] — the same source-agnostic
//! shape every other producer (HF discovery, on-disk scans, the legacy table)
//! yields — so the catalog is "just another producer". Its explicit `capabilities`
//! map becomes a [`CapabilityProbe`] with confident `Some(..)` values; the runtime
//! `GgufHeaderProber` is the same shape with `None` where a header omits a key,
//! which is why the two are interchangeable (the catalog is a baked probe).

use std::collections::HashMap;

use once_cell::sync::Lazy;
use serde::Deserialize;

use crate::managers::model::{
    default_quant_file, EngineType, ModelDescriptor, ModelSource, QuantFile,
};
use crate::managers::model_capabilities::{CapabilityProbe, Compatibility};

#[derive(Deserialize)]
struct CatalogRoot {
    models: Vec<CatalogModel>,
}

/// One model as written in `catalog.json`. Only the fields the descriptor needs
/// are declared; serde ignores the rest (slug, family, license, …).
#[derive(Deserialize)]
struct CatalogModel {
    /// HF repo id, e.g. `handy-computer/whisper-small-gguf`.
    id: String,
    name: String,
    description: String,
    architecture: Option<String>,
    languages: Vec<String>,
    capabilities: CatalogCaps,
    speed_score: Option<f32>,
    accuracy_score: Option<f32>,
    files: Vec<QuantFile>,
    default_quant: Option<String>,
    recommended_rank: Option<u32>,
    /// Part of the small curated onboarding set (badged "Recommended"). Distinct
    /// from `recommended_rank`, which only orders the full list.
    #[serde(default)]
    recommended: bool,
}

#[derive(Deserialize)]
struct CatalogCaps {
    streaming: bool,
    translate: bool,
    lang_detect: bool,
    // `timestamps` (a string enum) is present in the catalog but has no
    // `CapabilityProbe` field yet — wire it through when the probe gains one.
}

impl From<CatalogModel> for ModelDescriptor {
    fn from(m: CatalogModel) -> Self {
        // The default download file. Its name is folded into the id so a catalog
        // entry collides (dedups) with the very same file later discovered in
        // the HF cache — both compute `"{repo_id}/{filename}"`.
        let default_filename = default_quant_file(&m.files, m.default_quant.as_deref())
            .map(|f| f.filename.clone())
            .unwrap_or_default();

        ModelDescriptor {
            id: format!("{}/{}", m.id, default_filename),
            source: ModelSource::HuggingFace {
                repo_id: m.id,
                revision: "main".to_string(),
            },
            name: m.name,
            description: m.description,
            engine_type: EngineType::TranscribeCpp,
            caps: CapabilityProbe {
                verdict: Compatibility::Compatible, // curated org models we ship support for
                display_name: None,
                architecture: m.architecture,
                variant: None,
                languages: Some(m.languages),
                supports_streaming: Some(m.capabilities.streaming),
                supports_translation: Some(m.capabilities.translate),
                supports_language_detect: Some(m.capabilities.lang_detect),
            },
            files: m.files,
            default_quant: m.default_quant,
            // catalog scores are 0–100; ModelInfo / the UI bars use 0.0–1.0.
            speed_score: m.speed_score.unwrap_or(0.0) / 100.0,
            accuracy_score: m.accuracy_score.unwrap_or(0.0) / 100.0,
            recommended_rank: m.recommended_rank,
            recommended: m.recommended,
        }
    }
}

/// The bundled catalog, parsed once and normalised into descriptors.
pub static CATALOG: Lazy<Vec<ModelDescriptor>> = Lazy::new(|| {
    let root: CatalogRoot = serde_json::from_str(include_str!("catalog.json"))
        .expect("bundled catalog.json is valid JSON matching the catalog schema");
    root.models.into_iter().map(ModelDescriptor::from).collect()
});

/// Editorial recommended rank keyed by descriptor id (the same id the model
/// registry uses). Built once from the catalog.
static RANK_BY_ID: Lazy<HashMap<String, u32>> = Lazy::new(|| {
    CATALOG
        .iter()
        .filter_map(|d| d.recommended_rank.map(|r| (d.id.clone(), r)))
        .collect()
});

/// Recommended rank for a model id (lower = higher priority). Returns
/// `u32::MAX` for unranked/unknown ids so they sort last in an ascending sort.
pub fn rank_of(model_id: &str) -> u32 {
    RANK_BY_ID.get(model_id).copied().unwrap_or(u32::MAX)
}

/// Stable id for the Apple SpeechAnalyzer catalog entry — a slug, not a
/// downloadable HF path (there's no file to fetch for a `ModelSource::System`
/// model).
const APPLE_SPEECH_ID: &str = "apple-speechanalyzer";

/// The bundled catalog plus the availability-gated "Built-in (Apple)" entry.
///
/// Pure and deterministic: `available` is the only input, so tests can cover
/// both branches without touching the OS. No FFI call lives in this function
/// or anything it calls — the entry's `languages` come back empty here on
/// purpose; the real caller ([`apple_augmented_catalog`]) is the one place
/// allowed to call into `apple_speech` and patches the real locale list in
/// afterwards.
pub fn catalog_models_with_apple(available: bool) -> Vec<ModelDescriptor> {
    let mut models = CATALOG.clone();
    if available {
        models.push(ModelDescriptor {
            id: APPLE_SPEECH_ID.to_string(),
            source: ModelSource::System,
            name: "Built-in (Apple)".to_string(),
            description: "On-device speech recognition built into macOS 26+.".to_string(),
            engine_type: EngineType::AppleSpeech,
            caps: CapabilityProbe {
                verdict: Compatibility::Compatible,
                display_name: None,
                architecture: None,
                variant: None,
                // Patched with the real locale list by `apple_augmented_catalog`;
                // left empty here to keep this function FFI-free.
                languages: Some(Vec::new()),
                supports_streaming: Some(false),
                supports_translation: Some(false),
                // Apple's on-device transcriber requires an explicit locale, like
                // the Canary (NeMo) catalog entries — no auto-detect.
                supports_language_detect: Some(false),
            },
            files: Vec::new(),
            default_quant: None,
            // No benchmark exists yet for the Apple backend; these are
            // best-guess placeholders (fast — no model load; accuracy assumed
            // roughly on par with a mid-size Whisper), not measured scores.
            speed_score: 0.9,
            accuracy_score: 0.7,
            recommended_rank: None,
            recommended: false,
        });
    }
    models
}

/// The catalog Handy actually seeds into the model registry: [`catalog_models_with_apple`]
/// gated on the real availability check, with the Apple entry's `languages`
/// filled in from the real locale list. This — not the pure helper — is what
/// callers outside this module should use; it's the only place in the catalog
/// module allowed to call into `apple_speech`.
pub fn apple_augmented_catalog() -> Vec<ModelDescriptor> {
    let mut models = catalog_models_with_apple(crate::apple_speech::available());
    if let Some(apple) = models
        .iter_mut()
        .find(|d| matches!(d.engine_type, EngineType::AppleSpeech))
    {
        apple.caps.languages = Some(crate::apple_speech::supported_locales());
    }
    models
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::managers::model_capabilities::KNOWN_ARCHES;
    use std::collections::BTreeSet;

    #[test]
    fn catalog_parses_and_is_nonempty() {
        assert!(!CATALOG.is_empty(), "bundled catalog should contain models");
    }

    #[test]
    fn ids_are_unique() {
        let mut ids: Vec<&str> = CATALOG.iter().map(|d| d.id.as_str()).collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(before, ids.len(), "catalog descriptor ids must be unique");
    }

    #[test]
    fn scores_are_normalised_0_to_1() {
        for d in CATALOG.iter() {
            assert!((0.0..=1.0).contains(&d.speed_score), "{} speed", d.id);
            assert!((0.0..=1.0).contains(&d.accuracy_score), "{} acc", d.id);
        }
    }

    #[test]
    fn catalog_architectures_are_known_to_capability_probe() {
        let missing: BTreeSet<&str> = CATALOG
            .iter()
            .filter_map(|d| d.caps.architecture.as_deref())
            .filter(|arch| !KNOWN_ARCHES.contains(arch))
            .collect();

        assert!(
            missing.is_empty(),
            "catalog architecture(s) missing from KNOWN_ARCHES: {:?}",
            missing
        );
    }

    #[test]
    fn apple_entry_absent_when_unavailable() {
        let entries = catalog_models_with_apple(false);
        assert!(
            !entries
                .iter()
                .any(|m| matches!(m.engine_type, EngineType::AppleSpeech)),
            "no AppleSpeech entry should be present when unavailable"
        );
    }

    #[test]
    fn apple_entry_present_when_available() {
        let entries = catalog_models_with_apple(true);
        let apple: Vec<_> = entries
            .iter()
            .filter(|m| matches!(m.engine_type, EngineType::AppleSpeech))
            .collect();
        assert_eq!(apple.len(), 1, "exactly one AppleSpeech entry expected");
        let apple = apple[0];
        assert_eq!(apple.name, "Built-in (Apple)");
        assert!(matches!(apple.source, ModelSource::System));
        assert_eq!(apple.caps.supports_streaming, Some(false));
        assert_eq!(apple.caps.supports_translation, Some(false));
    }

    #[test]
    fn apple_entry_does_not_shadow_or_duplicate_catalog_ids() {
        let entries = catalog_models_with_apple(true);
        let mut ids: Vec<&str> = entries.iter().map(|d| d.id.as_str()).collect();
        ids.sort_unstable();
        let before = ids.len();
        ids.dedup();
        assert_eq!(before, ids.len(), "apple entry id must not collide");
    }
}

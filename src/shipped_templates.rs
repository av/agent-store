//! Fingerprints of every builtin skill text and managed instructions block
//! that an agent-store release (or master build) has installed. `init` uses
//! them to tell an untouched copy from an earlier version, which it refreshes,
//! from a user-edited copy, which it leaves alone.
//!
//! When a builtin template changes, append the new text's hash here and keep
//! the old ones: the `current_templates_are_recorded` test fails and prints
//! the entry to add.

/// `(skill name, fnv1a64(SKILL.md text))`.
pub(crate) const SHIPPED_SKILLS: &[(&str, u64)] = &[
    ("agent-store", 0x1a854130fc821fc4),           // v0.1.0
    ("agent-store", 0xc2027b6cd5277a1c),           // v0.1.1 - v0.1.2
    ("agent-store-patterns", 0x8e2d9ac99129f99d),  // v0.1.0 - v0.1.2
    ("agent-store-pipelines", 0x0a0f3a891ce76026), // v0.1.0 - v0.1.2
];

/// `fnv1a64` of the managed block from the start marker through the end
/// marker, without the trailing newline.
pub(crate) const SHIPPED_INSTRUCTION_BLOCKS: &[u64] = &[
    0xc956e7887fe38863, // v0.1.0 - v0.1.2
];

pub(crate) fn shipped_skill_hashes(name: &str) -> Vec<u64> {
    SHIPPED_SKILLS
        .iter()
        .filter(|(skill, _)| *skill == name)
        .map(|(_, hash)| *hash)
        .collect()
}

/// 64-bit FNV-1a: stable across platforms and releases, no dependency.
pub(crate) fn fnv1a64(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf29ce484222325, |hash, byte| {
        (hash ^ u64::from(*byte)).wrapping_mul(0x100000001b3)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn current_templates_are_recorded() {
        for skill in crate::BUILTIN_SKILLS {
            let hash = fnv1a64(skill.content.as_bytes());
            assert!(
                shipped_skill_hashes(skill.name).contains(&hash),
                "add (\"{}\", {hash:#018x}) to SHIPPED_SKILLS",
                skill.name
            );
        }
        let block = crate::INSTRUCTIONS_BLOCK.trim_end_matches('\n');
        let hash = fnv1a64(block.as_bytes());
        assert!(
            SHIPPED_INSTRUCTION_BLOCKS.contains(&hash),
            "add {hash:#018x} to SHIPPED_INSTRUCTION_BLOCKS"
        );
    }

    #[test]
    fn fnv1a64_matches_reference_vectors() {
        assert_eq!(fnv1a64(b""), 0xcbf29ce484222325);
        assert_eq!(fnv1a64(b"a"), 0xaf63dc4c8601ec8c);
        assert_eq!(fnv1a64(b"foobar"), 0x85944171f73967e8);
    }
}

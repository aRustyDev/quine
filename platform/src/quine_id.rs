// platform/src/quine_id.rs
//
// Deterministic QuineId generation from strings and shard routing.
// Must match the Roc-side Routing.shard_for_node (FNV-1a-32).

/// Generate a 16-byte QuineId from a string using FNV-1a-128.
///
/// The same string always produces the same QuineId. Bytes are little-endian.
pub fn quine_id_from_str(s: &str) -> [u8; 16] {
    fnv1a_128(s.as_bytes()).to_le_bytes()
}

/// Determine which shard owns a QuineId.
///
/// Uses FNV-1a-32 on the raw QuineId bytes, matching the Roc-side
/// `Routing.shard_for_node` (offset basis 2166136261, prime 16777619).
pub fn shard_for_node(qid_bytes: &[u8], shard_count: u32) -> u32 {
    fnv1a_32(qid_bytes) % shard_count
}

fn fnv1a_128(bytes: &[u8]) -> u128 {
    const OFFSET_BASIS: u128 = 144066263297769815596495629667062367629;
    const PRIME: u128 = 309485009821345068724781371;
    let mut hash = OFFSET_BASIS;
    for &b in bytes {
        hash ^= b as u128;
        hash = hash.wrapping_mul(PRIME);
    }
    hash
}

fn fnv1a_32(bytes: &[u8]) -> u32 {
    let mut hash: u32 = 2166136261;
    for &b in bytes {
        hash ^= b as u32;
        hash = hash.wrapping_mul(16777619);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_string_same_id() {
        assert_eq!(quine_id_from_str("alice"), quine_id_from_str("alice"));
    }

    #[test]
    fn different_strings_different_ids() {
        assert_ne!(quine_id_from_str("alice"), quine_id_from_str("bob"));
    }

    #[test]
    fn id_is_16_bytes() {
        let id = quine_id_from_str("test");
        assert_eq!(id.len(), 16);
    }

    #[test]
    fn shard_routing_deterministic() {
        let id = quine_id_from_str("alice");
        let s1 = shard_for_node(&id, 4);
        let s2 = shard_for_node(&id, 4);
        assert_eq!(s1, s2);
    }

    #[test]
    fn shard_routing_in_range() {
        for i in 0..100u32 {
            let id = quine_id_from_str(&format!("node-{}", i));
            let shard = shard_for_node(&id, 4);
            assert!(shard < 4, "shard {} out of range for node-{}", shard, i);
        }
    }

    #[test]
    fn shard_routing_distributes() {
        // 100 distinct IDs across 4 shards should hit at least 2
        let mut seen = std::collections::HashSet::new();
        for i in 0..100u32 {
            let id = quine_id_from_str(&format!("node-{}", i));
            seen.insert(shard_for_node(&id, 4));
        }
        assert!(seen.len() >= 2, "poor distribution: only {} shards hit", seen.len());
    }

    #[test]
    fn fnv1a_32_matches_roc() {
        // Verify against Roc's hash_bytes: offset 2166136261, prime 16777619
        // For empty input, hash = offset_basis
        assert_eq!(fnv1a_32(&[]), 2166136261);

        // For single byte 0x00: XOR with 0 = offset_basis, then * prime
        let expected = 2166136261u32.wrapping_mul(16777619);
        assert_eq!(fnv1a_32(&[0x00]), expected);
    }

    #[test]
    fn single_shard_always_zero() {
        let id = quine_id_from_str("anything");
        assert_eq!(shard_for_node(&id, 1), 0);
    }
}

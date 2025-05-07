use snafu::prelude::*;
use std::collections::BTreeMap;
use std::str::FromStr;

#[derive(Debug, PartialEq)]
pub struct GemfileChecksums {
    map: BTreeMap<GemPlatform, BTreeMap<GemName, Gem>>,
}

type GemName = String;
type GemVersion = String;
type GemHash = String;
type GemPlatform = String;

#[derive(Debug, PartialEq)]
pub struct Gem {
    name: GemName,
    platform: GemPlatform,
    version: GemVersion,
    hash: GemHash,
}

#[derive(Debug, Snafu)]
pub enum GemParseError {
    MalformedLine { line: String },
}

impl FromStr for Gem {
    type Err = GemParseError;

    // "name (version-platform) sha256=hash"
    fn from_str(line: &str) -> Result<Self, Self::Err> {
        // split off "sha256=hash" from end of the line
        let (rest, hash) = line
            .rsplit_once(' ')
            .ok_or_else(|| GemParseError::MalformedLine {
                line: line.to_string(),
            })?;
        // split the hash value from sha256 on "="
        let (_, hash) = hash
            .rsplit_once('=')
            .ok_or_else(|| GemParseError::MalformedLine {
                line: line.to_string(),
            })?;
        // we have our hash
        let hash = hash.into();

        // gem name precedes the parenthesized version info
        let (name, version_part) = rest.split_once(" (").context(MalformedLineSnafu { line })?;
        let name = name.into();

        // version info is what remains, with optional trailing-hyphenated platform
        let version_part = version_part.trim_end_matches(')');
        let (version, platform) = match version_part.split_once('-') {
            Some((version, platform)) => (version.into(), platform.into()),
            None => (version_part.into(), "ruby".into()),
        };

        Ok(Gem {
            name,
            version,
            platform,
            hash,
        })
    }
}

impl GemfileChecksums {
    pub fn to_nix(&self) -> String {
        let mut s = String::new();
        s.push_str("{\n");
        for (platform, gems) in &self.map {
            s.push_str(&format!("  \"{platform}\" = {{\n"));
            for (name, Gem { version, hash, .. }) in gems {
                s.push_str(&format!("    \"{name}\" = {{\n"));
                s.push_str(&format!("      \"name\" = \"{name}\";\n"));
                s.push_str(&format!("      \"version\" = \"{version}\";\n"));
                s.push_str(&format!("      \"hash\" = \"{hash}\";\n"));
                s.push_str("    };\n")
            }
            s.push_str("  };\n")
        }
        s.push('}');
        s
    }
}

#[derive(Debug, Snafu)]
pub enum GemfileChecksumsParseError {
    GemParse { source: GemParseError },
}

impl FromStr for GemfileChecksums {
    type Err = GemfileChecksumsParseError;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        let mut lines = s.lines().map(str::trim);
        let mut map: BTreeMap<GemPlatform, BTreeMap<GemName, Gem>> = BTreeMap::new();

        // advance to CHECKSUMS section
        for line in lines.by_ref() {
            if line == "CHECKSUMS" {
                break;
            }
        }

        // within CHECKSUMS, parse each line into a Gem
        for line in lines {
            if line.is_empty() {
                break;
            }
            let gem: Gem = line.parse().context(GemParseSnafu)?;
            map.entry(gem.platform.clone())
                .or_default()
                .insert(gem.name.clone(), gem);
        }

        Ok(Self { map })
    }
}

#[test]
fn parse() {
    let input = r#"
CHECKSUMS
  abbrev (0.1.2) sha256=ad1b4eaaaed4cb722d5684d63949e4bde1d34f2a95e20db93aecfe7cbac74242
  ffi (1.17.0) sha256=51630e43425078311c056ca75f961bb3bda1641ab36e44ad4c455e0b0e4a231c
  ffi (1.17.0-arm64-darwin) sha256=609c874e76614542c6d485b0576e42a7a38ffcdf086612f9a300c4ec3fcd0d12

RUBY VERSION
  ruby 3.3.5p100

BUNDLED WITH
  2.6.7
"#;
    let parsed: GemfileChecksums = input.parse().unwrap();
    let expected = GemfileChecksums {
        map: BTreeMap::from([
            (
                "ruby".into(),
                BTreeMap::from([
                    (
                        "abbrev".into(),
                        Gem {
                            name: "abbrev".into(),
                            platform: "ruby".into(),
                            version: "0.1.2".into(),
                            hash:
                                "ad1b4eaaaed4cb722d5684d63949e4bde1d34f2a95e20db93aecfe7cbac74242"
                                    .into(),
                        },
                    ),
                    (
                        "ffi".into(),
                        Gem {
                            name: "ffi".into(),
                            platform: "ruby".into(),
                            version: "1.17.0".into(),
                            hash:
                                "51630e43425078311c056ca75f961bb3bda1641ab36e44ad4c455e0b0e4a231c"
                                    .into(),
                        },
                    ),
                ]),
            ),
            (
                "arm64-darwin".into(),
                BTreeMap::from([(
                    "ffi".into(),
                    Gem {
                        name: "ffi".into(),
                        platform: "arm64-darwin".into(),
                        version: "1.17.0".into(),
                        hash: "609c874e76614542c6d485b0576e42a7a38ffcdf086612f9a300c4ec3fcd0d12"
                            .into(),
                    },
                )]),
            ),
        ]),
    };
    pretty_assertions::assert_eq!(expected, parsed);
}

#[test]
fn serialize_to_nix() {
    let input = r#"
CHECKSUMS
  abbrev (0.1.2) sha256=ad1b4eaaaed4cb722d5684d63949e4bde1d34f2a95e20db93aecfe7cbac74242
"#;
    let parsed: GemfileChecksums = input.parse().unwrap();

    let expected_nix = r#"{
  "ruby" = {
    "abbrev" = {
      "name" = "abbrev";
      "version" = "0.1.2";
      "hash" = "ad1b4eaaaed4cb722d5684d63949e4bde1d34f2a95e20db93aecfe7cbac74242";
    };
  };
}"#;
    pretty_assertions::assert_eq!(expected_nix, parsed.to_nix().trim());

    let input = r#"
CHECKSUMS
  abbrev (0.1.2) sha256=ad1b4eaaaed4cb722d5684d63949e4bde1d34f2a95e20db93aecfe7cbac74242
  ffi (1.17.0) sha256=51630e43425078311c056ca75f961bb3bda1641ab36e44ad4c455e0b0e4a231c
  ffi (1.17.0-arm64-darwin) sha256=609c874e76614542c6d485b0576e42a7a38ffcdf086612f9a300c4ec3fcd0d12
"#;
    let parsed: GemfileChecksums = input.parse().unwrap();
    let expected_nix_pretty = r#"{
  "arm64-darwin" = {
    "ffi" = {
      "name" = "ffi";
      "version" = "1.17.0";
      "hash" = "609c874e76614542c6d485b0576e42a7a38ffcdf086612f9a300c4ec3fcd0d12";
    };
  };
  "ruby" = {
    "abbrev" = {
      "name" = "abbrev";
      "version" = "0.1.2";
      "hash" = "ad1b4eaaaed4cb722d5684d63949e4bde1d34f2a95e20db93aecfe7cbac74242";
    };
    "ffi" = {
      "name" = "ffi";
      "version" = "1.17.0";
      "hash" = "51630e43425078311c056ca75f961bb3bda1641ab36e44ad4c455e0b0e4a231c";
    };
  };
}"#;
    pretty_assertions::assert_eq!(expected_nix_pretty, parsed.to_nix().trim());
}

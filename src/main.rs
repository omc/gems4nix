mod gemfile;

use gemfile::{GemfileChecksums, GemfileChecksumsParseError};
use snafu::prelude::*;
use std::path::PathBuf;

fn main() -> Result<(), Error> {
    let path: PathBuf = std::env::args()
        .nth(1)
        .expect("usage: gems4nix <Gemfile.lock path>")
        .parse()
        .unwrap(/* <PathBuf as FromStr>::Err is Infallible */);
    let contents = std::fs::read_to_string(&path).context(ReadGemfileSnafu)?;
    let gems: GemfileChecksums = contents.parse().context(ParseGemfileSnafu)?;
    println!("{}", gems.to_nix());
    Ok(())
}

#[derive(Debug, Snafu)]
enum Error {
    ReadGemfile { source: std::io::Error },
    ParseGemfile { source: GemfileChecksumsParseError },
}

# Per-gem build configuration overrides.
#
# These are layered between defaultGemConfig (from nixpkgs) and user-supplied
# gemConfig: defaultGemConfig < gemConfigs < user gemConfig.
#
# callPackage definitions:
{
  lib,
  stdenv,
  zlib,
  libxml2,
  libxslt,
  libiconv,
}:

{
  nokogiri =
    attrs:
    (
      {
        buildFlags = [
          "--use-system-libraries"
          "--with-zlib-lib=${zlib.out}/lib"
          "--with-zlib-include=${zlib.dev}/include"
          "--with-xml2-lib=${libxml2.out}/lib"
          "--with-xml2-include=${libxml2.dev}/include/libxml2"
          "--with-xslt-lib=${libxslt.out}/lib"
          "--with-xslt-include=${libxslt.dev}/include"
          "--with-exslt-lib=${libxslt.out}/lib"
          "--with-exslt-include=${libxslt.dev}/include"
          "--gumbo-dev"
        ]
        ++ lib.optionals stdenv.hostPlatform.isDarwin [
          "--with-iconv-dir=${libiconv}"
          "--with-opt-include=${libiconv}/include"
        ];
      }
      // lib.optionalAttrs stdenv.hostPlatform.isDarwin {
        buildInputs = [ libxml2 ];

        # libxml 2.12 upgrade requires these fixes
        # https://github.com/sparklemotion/nokogiri/pull/3032
        # which don't trivially apply to older versions
        meta.broken =
          (lib.versionOlder attrs.version "1.16.0") && (lib.versionAtLeast libxml2.version "2.12");
      }
    );
}

# frozen_string_literal: true

module Authoring
  # Does a piece of text carry a credential VALUE? Judged by what the value looks like, never by the name it sits under
  # and never by how random it is: a Drive id, a base64 file id, a page token and a Stripe object id are ordinary, and a
  # false refusal blocks real work. Two strengths:
  #
  # - `provider_key?`: a whole key in a known provider format, a JWT, or a PEM private key. Nothing legitimate looks like
  #   this, so it is what a web save is warned about.
  # - `credential?`: those, plus a Bearer/Basic value shaped like a token and a URL with user:password. This is for text an
  #   agent supplies, where the author is untrusted.
  #
  # `{{...}}` placeholders and invisible characters are dealt with before the scan, so a key can't hide behind a
  # zero-width space and "Bearer {{context:token}}" is not a credential.
  module CredentialScan
    PLACEHOLDER = /\{\{[^{}\n]*\}\}/
    INVISIBLE = /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}\p{Variation_Selector}ᅟᅠㅤﾠ⠀]/
    EDGE = "(?<![A-Za-z0-9])"

    PROVIDER_KEY = Regexp.new(
      [ "#{EDGE}(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}", "#{EDGE}whsec_[A-Za-z0-9]{24,}",
        "#{EDGE}sk-ant-[A-Za-z0-9_-]{20,}", "#{EDGE}sk-proj-[A-Za-z0-9_-]{20,}", "#{EDGE}sk-(?=[A-Za-z0-9]*\\d)[A-Za-z0-9]{20,}",
        "#{EDGE}gh[pousr]_[A-Za-z0-9]{30,}", "#{EDGE}github_pat_[A-Za-z0-9_]{30,}", "#{EDGE}glpat-[A-Za-z0-9_-]{20,}",
        "#{EDGE}xox[abprs]-[A-Za-z0-9-]{10,}", "#{EDGE}xapp-[A-Za-z0-9-]{16,}", "#{EDGE}(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Za-z0-9])",
        "#{EDGE}AIza[0-9A-Za-z_-]{35}", "#{EDGE}SG\\.[A-Za-z0-9_-]{16,}\\.[A-Za-z0-9_-]{16,}", "#{EDGE}shpat_[a-f0-9]{32}",
        "#{EDGE}npm_[A-Za-z0-9]{36}", "#{EDGE}dop_v1_[a-f0-9]{64}", "#{EDGE}hf_[A-Za-z0-9]{34}",
        "#{EDGE}eyJ[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]*",
        "-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----" ].join("|")
    )
    TOKEN_VALUE = %r{#{EDGE}(?:Bearer|Basic)\s+(?=[A-Za-z0-9._~+/-]*\d)[A-Za-z0-9._~+/-]{16,}=*}
    USERINFO = %r{://[^/\s:@]+:[^/\s@]+@}

    module_function

    def normalize(text) = text.to_s.gsub(INVISIBLE, "").gsub(PLACEHOLDER, " ")

    def provider_key?(text) = normalize(text).match?(PROVIDER_KEY)

    def credential?(text)
      plain = normalize(text)
      plain.match?(PROVIDER_KEY) || plain.match?(TOKEN_VALUE) || plain.match?(USERINFO)
    end
  end
end

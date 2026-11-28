package mobile

import "testing"

func TestProfileLinkParseComponents(t *testing.T) {
	link := profileLinkParse("http://user:p%40ss@EXAMPLE.com:8080/a%20b?x=1&y=%2B#frag")
	if link.Scheme != "http" || link.UserName != "user" || link.Password != "p@ss" {
		t.Fatalf("scheme/userinfo = %q/%q/%q", link.Scheme, link.UserName, link.Password)
	}
	if link.Host != "example.com" || link.Port != 8080 {
		t.Fatalf("host/port = %q/%d", link.Host, link.Port)
	}
	if link.Path != "/a b" {
		t.Fatalf("path = %q", link.Path)
	}
	if link.Query.Value("x") != "1" || link.Query.Value("y") != "%2B" {
		t.Fatalf("query = %#v", link.Query.Items)
	}
	if !link.HasFragment || link.Fragment != "frag" {
		t.Fatalf("fragment = %q/%v", link.Fragment, link.HasFragment)
	}
	if !link.IsValid() || link.InvalidPortOnly() {
		t.Fatalf("validity = %v/%v", link.IsValid(), link.InvalidPortOnly())
	}
}

func TestProfileLinkParseAuthorityEdges(t *testing.T) {
	ipv6 := profileLinkParse("http://[2001:DB8::1]:8080/")
	if ipv6.Host != "2001:db8::1" || ipv6.Port != 8080 {
		t.Fatalf("ipv6 = %q/%d", ipv6.Host, ipv6.Port)
	}
	badPort := profileLinkParse("http://host:99999/")
	if !badPort.InvalidPort || !badPort.InvalidPortOnly() || badPort.Host != "host" {
		t.Fatalf("bad port = %+v", badPort)
	}
	badHost := profileLinkParse("http://exa mple.com/")
	if !badHost.InvalidHost || badHost.IsValid() {
		t.Fatalf("bad host = %+v", badHost)
	}
	noAuthority := profileLinkParse("vless://?security=tls")
	if noAuthority.Scheme != "vless" || noAuthority.Query.Value("security") != "tls" {
		t.Fatalf("no authority = %+v", noAuthority)
	}
	if noAuthority.Host != "" || !noAuthority.IsValid() {
		t.Fatalf("empty host should stay valid: %+v", noAuthority)
	}
}

func TestProfileLinkQueryDecoding(t *testing.T) {
	link := profileLinkParse("vless://host:443/?sni=a%20b&type=ws&path=%2Fws%3Fed%3D2048")
	if got := link.Query.Value("sni"); got != "a b" {
		t.Fatalf("pretty sni = %q", got)
	}
	if got := link.Query.ValueFully("path"); got != "/ws?ed=2048" {
		t.Fatalf("fully path = %q", got)
	}
	form := profileLinkParse("trojan://pass@host:443/?pbk=abc%2Bdef&x=a+b")
	if got := form.Query.ValueFormDecoded("pbk"); got != "abc+def" {
		t.Fatalf("form pbk = %q", got)
	}
	if got := form.Query.ValueFormDecoded("x"); got != "a b" {
		t.Fatalf("form x = %q", got)
	}
	tolerant := profileLinkParse("ss://host:443/?q=%zz&ok=%41")
	if got := tolerant.Query.Value("q"); got != "%25zz" {
		t.Fatalf("tolerant q = %q", got)
	}
	if got := tolerant.Query.Value("ok"); got != "%2541" {
		t.Fatalf("tolerant ok = %q", got)
	}
}

func TestProfileLinkUserInfoPair(t *testing.T) {
	link := profileLinkParse("hysteria2://id%3Asecret@host:443/")
	user, password := link.UserInfoPair()
	if user != "id" || password != "secret" {
		t.Fatalf("encoded colon pair = %q/%q", user, password)
	}
	link = profileLinkParse("hysteria2://id:secret@host:443/")
	user, password = link.UserInfoPair()
	if user != "id" || password != "secret" {
		t.Fatalf("literal colon pair = %q/%q", user, password)
	}
}

func TestProfileLinkCodecEncoders(t *testing.T) {
	if got := profileLinkEncodeUserName("a b@c"); got != "a%20b%40c" {
		t.Fatalf("user = %q", got)
	}
	if got := profileLinkEncodeQueryPart("a/b?c=d&e"); got != "a/b?c%3Dd%26e" {
		t.Fatalf("query = %q", got)
	}
	if got := profileLinkEncodeFragment("a b#c"); got != "a%20b%23c" {
		t.Fatalf("fragment = %q", got)
	}
	if got := profileLinkPercentEncodeAll("a b/节"); got != "a%20b%2F%E8%8A%82" {
		t.Fatalf("all = %q", got)
	}
}

func TestProfileLinkCodecDecoders(t *testing.T) {
	if got := profileLinkDecodeFully("%E8%8A%82%E7%82%B9"); got != "节点" {
		t.Fatalf("fully = %q", got)
	}
	if got := profileLinkDecodeFully("a%ZZb"); got != "a%ZZb" {
		t.Fatalf("malformed escape stays literal = %q", got)
	}
	if got := profileLinkDecodeFully("a%80b"); got != "a\uFFFDb" {
		t.Fatalf("invalid utf8 escape = %q", got)
	}
	if got := profileLinkDecodePretty("%2B%2F%25%20"); got != "%2B%2F%25 " {
		t.Fatalf("pretty = %q", got)
	}
	if got := profileLinkRecodeQueryFullyEncoded("a b+c%2B"); got != "a%20b+c%2B" {
		t.Fatalf("recode = %q", got)
	}
	if got := profileLinkTolerant("x%zz"); got != "x%25zz" {
		t.Fatalf("tolerant = %q", got)
	}
}

func TestProfileLinkQueryOrderAndDefaults(t *testing.T) {
	link := profileLinkParse("socks://host:1080/?a=1&b=&a=2")
	if got := link.Query.Value("a"); got != "1" {
		t.Fatalf("first a = %q", got)
	}
	if got := link.Query.ValueOr("b", "fallback"); got != "fallback" {
		t.Fatalf("empty default = %q", got)
	}
	if !link.Query.Has("a") || link.Query.Has("missing") {
		t.Fatalf("has = %#v", link.Query.Items)
	}
}

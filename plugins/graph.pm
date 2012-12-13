use POE;
use HTML::HTML5::Parser;
use HTML::Entities;
use HTTP::Request::Common;
use JSON;
use URI::Escape;
use XML::LibXML::XPathContext;

my $baseurl = $BotIrc::cfg{graph_baseurl} // "http://g.jk.gs";

my $dograph = sub {
	my ($type, $text) = @_;
	BotIrc::check_ctx() or return;
	my $req = POST("$baseurl/gen.php", [type => $type, def => $text]);
	$ctx = BotIrc::ctx_frozen;

	BotHttp::request($req, sub {
		my $dom = eval { HTML::HTML5::Parser->new->parse_string(shift); };
		if ($@) {
			BotIrc::send_noise($ctx, ".$type error: parsing HTML: $@");
			return;
		}
		my $xpc = XML::LibXML::XPathContext->new($dom);
		$xpc->registerNs('x', 'http://www.w3.org/1999/xhtml');
		my @nodes = $xpc->findnodes('//x:pre[1]');
		if (@nodes) {
			my $err = $nodes[0]->textContent;
			chomp $err;
			$err =~ s/[\r\n]+/ | /g;
			BotIrc::send_noise($ctx, ".$type error processing the definition: $err");
			return;
		}
		my $src = $xpc->findvalue('//x:img/@src');
		if (!defined $src) {
			BotIrc::send_noise($ctx, ".$type error: couldn't find generated image, sorry");
			return;
		}
		BotIrc::send_wisdom($ctx, ".$type: $baseurl/$src");
	}, sub {
		BotIrc::send_noise($ctx, ".$type error: graph generation failed: ".shift);
		return;
	});
};

{
	irc_commands => {
		graph	=> sub { $dograph->('graph', $_[2]); },
		digraph	=> sub { $dograph->('digraph', $_[2]); },
	},
};

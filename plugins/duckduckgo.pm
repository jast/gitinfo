use POE;
use HTTP::Request::Common;
use JSON;
use Mojo::DOM;
use URI::Escape;

my $dolink = sub { BotPlugin::call('templink', 'make', shift); };
{
	dependencies => [ 'templink' ],
	irc_commands => {
		info	=> sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return;
			my $nick = BotIrc::nickonly($source);
			my $ctx = BotIrc::ctx_frozen;

			BotHttp::get("http://duckduckgo.com/?q=".uri_escape($args)."&format=json&no_redirect=1&no_html=1&skip_disambig=1", sub {
				my $data = eval { decode_json(shift); };
				if ($@) {
					BotIrc::send_noise($ctx, ".info error: parsing JSON: $@");
					return;
				}
				# Most interested in: related topics
				if ($data->{Type} =~ /^[CD]$/o) {
					my @topics = @{$data->{RelatedTopics}};
					my $suffix = (@topics > 5) ? " | ..." : "";
					splice @topics, 5;
					my $topics = join(" | ", map { "$_->{Text} <". $dolink->($_->{FirstURL}) .">" } @topics);
					BotIrc::send_wisdom($ctx, "$topics$suffix");
					return;
				}
				# Bang command
				if ($data->{Redirect}) {
					BotIrc::send_wisdom($ctx, $dolink->($data->{Redirect}));
					return;
				}
				# Answer from calculator etc.
				if ($data->{Answer} && $data->{AnswerType}) {
					BotIrc::send_wisdom($ctx, "[$data->{AnswerType}] $data->{Answer}");
					return;
				}
				# Abstract
				if ($data->{AbstractText}) {
					BotIrc::send_wisdom($ctx, "$data->{Heading}: $data->{AbstractText} <$data->{AbstractURL}> [from $data->{AbstractSource}]");
					return;
				}
				# Definition
				if ($data->{Definition}) {
					BotIrc::send_wisdom($ctx, "$data->{Definition} <$data->{DefinitionURL}> [from $data->{DefinitionSource}]");
					return;
				}
				BotIrc::send_wisdom($ctx, ".info: nothing found.");
			}, sub {
				BotIrc::send_noise($ctx, ".info error: query '$args' failed: ".shift);
				return;
			});
		},
		search	=> sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return;
			my $nick = BotIrc::nickonly($source);
			my $req = POST('http://duckduckgo.com/html', [q => $args]);
			my $ctx = BotIrc::ctx_frozen;

			BotHttp::request($req, sub {
				my $dom;
				eval {
					$dom = Mojo::DOM->new(shift);
				};
				if ($@) {
					BotIrc::send_noise($ctx, ".search error: parsing HTML: $@");
					return;
				}
				my $nodes = $dom->find('.web-result');
				if (!$nodes || !@$nodes) {
					BotIrc::send_wisdom($ctx, ".search: nothing found.");
					return;
				}
				my $suffix = (@$nodes > 3) ? " | ..." : "";
				splice @$nodes, 3;
				$nodes = [ map {
					my $url = $_->at('a.large')->attr('href');
					my $title = $_->at('a.large')->all_text;
					$url = $dolink->($url) if $url;
					$url ? "$title <$url>" : undef;
				} @$nodes ];
				if (!$nodes->[0]) {
					BotIrc::send_wisdom($ctx, ".search: nothing found.");
					return;
				}
				$nodes = join(" | ", @$nodes);
				BotIrc::send_wisdom($ctx, "$nodes$suffix");
			}, sub {
				BotIrc::send_noise($ctx, ".search error: query '$args' failed: ".shift);
				return;
			});
		},
	},
};

use POE;
use version ();
use JSON ();

{
	irc_commands => {
		version	=> sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return;
			my $nick = BotIrc::nickonly($source);
			my $ctx = BotIrc::ctx_frozen;
			if (!defined $ctx->{channel}) {
				BotIrc::send_noise($ctx, ".version error: must be used in a channel");
				return;
			}
			my $chan = $ctx->{channel};
			if (lc($chan) ne lc($BotIrc::config->{version_channel})) {
				BotIrc::send_noise($ctx, ".version error: this command is really only useful in $BotIrc::config->{version_channel}");
				return;
			}

      BotHttp::get('https://api.github.com/repos/git/git/tags', sub {
        my $data = eval { JSON::decode_json( shift ); };
				if ($@) {
					BotIrc::send_noise($ctx, ".version error: parsing JSON: $@");
					return;
				}
        my @stable = sort { version->parse($a) <=> version->parse($b) }
                       grep { eval { version->parse($_) } }
                         map  { $_->{name} }
                           grep { defined $_->{name} }
                             @{ $data };

				( my $version = pop @stable ) =~ s!^v!!;
				if ($version !~ /^\d+(\.\d+)+$/) {
					BotIrc::send_noise($ctx, ".version error: secret source of version number is speaking in tongues...");
					return;
				}
				my $topic = $BotIrc::irc->channel_topic($chan) || do {
					BotIrc::send_noise($ctx, ".version error: topic not cached, can't do anything. Sorry.");
					return;
				};
				$topic = $topic->{Value};
				if ($topic !~ /\b(\d+(?:\.\d+)+)\b/) {
					BotIrc::send_noise($ctx, ".version error: no current version found in first part of topic; can't change anything.");
					return;
				}
				my $old_ver = $1;
				if ($old_ver eq $ver) {
					BotIrc::send_noise($ctx, ".version: still at $old_ver, not updating topic.");
					return;
				}
				$topic =~ s/$old_ver/$version/;
				$BotIrc::irc->yield(topic => $chan => $topic);
			}, sub {
				BotIrc::send_noise($ctx, ".version error: lookup failed: ".shift);
				return;
			});
		},
	},
};

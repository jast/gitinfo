use POE;
use version ();

{
	irc_commands => {
		version	=> sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return;
			my $nick = BotIrc::nickonly($source);
			my $ctx = BotIrc::ctx_frozen;
			my $chan = $BotIrc::config->{version_channel};

			my @tags = split(/[\015\012]+/, `GIT_DIR=$BotIrc::config->{git_repo} git tag -l`);
			chomp @tags;
			@tags = grep /^v\d(\.\d)*$/, @tags;
			@tags = map { $_ =~ s/^v//; [split(/\./, $_)] } @tags;
			@tags = sort {
				my $i = -1;
				while (++$i < @$a) {
					my $va = @$a[$i];
					my $vb = @$b[$i] // 0;
					next if $va eq $vb;
					return $vb <=> $va;
				}
				return 0;
			} @tags;

			if (!@tags) {
				BotIrc::send_noise($ctx, ".version error: repository contains no tags");
				return;
			}
			my $version = join('.',@{shift @tags});

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
			if ($old_ver eq $version) {
				BotIrc::send_noise($ctx, ".version: still at $old_ver, not updating topic.");
				return;
			}
			$topic =~ s/$old_ver/$version/;
			$BotIrc::irc->yield(topic => $chan => $topic);
		},
	},
};

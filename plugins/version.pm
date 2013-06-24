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

			my $version;
			my $newest_ver_norm;
			my @tags = split(/[\015\012]+/, `GIT_DIR=$BotIrc::config->{git_repo} git tag -l`);
			foreach my $tag (@tags) {
				next if $tag !~ /^v(\d(?:\.\d)*)\s*$/;
				my $v = $1;
				my @v = split(/\./, $v);
				$v[2] //= 0;
				$v[3] //= 0;
				my $v_norm = join('', map { sprintf("%03d", $_) } @v);
				if (!defined $newest_ver_norm || $newest_ver_norm lt $v_norm) {
					$newest_ver_norm = $v_norm;
					$version = $v;
				}
			}

			if (!defined $version) {
				BotIrc::send_noise($ctx, ".version error: repository contains no tags");
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
			if ($old_ver eq $version) {
				BotIrc::send_noise($ctx, ".version: still at $old_ver, not updating topic.");
				return;
			}
			$topic =~ s/$old_ver/$version/;
			$BotIrc::irc->yield(topic => $chan => $topic);
		},
	},
};

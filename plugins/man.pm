use POE;
{
	on_load => sub {
		$BotIrc::heap{man_cache} = undef;
	},
	before_unload => sub {
		delete $BotIrc::heap{man_cache};
	},
	irc_commands => {
		man_update => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx(authed => 1) or return;

			umask(0022);
			system("cd $BotIrc::config->{man_repodir} && git pull -q &");
			BotIrc::send_noise("Manpage index updating. Please allow a few seconds before using again.");
			$BotIrc::heap{man_cache} = undef;
		}
	},
	irc_on_anymsg => sub {
		return 0 if ($_[ARG2] !~ /\bman\s+([a-z-]+)/);
		BotIrc::check_ctx(wisdom_auto_redirect => 1) or return;

		if (!defined $BotIrc::heap{man_cache}) {
			my @mans = BotIrc::read_dir($BotIrc::config->{man_repodir}) or do {
				error("Manpage cache broken: $!");
				BotIrc::send_noise("Manpage cache is broken. The bot owner has been notified.");
				return 1;
			};
			@mans = grep { $_ =~ /\.html$/ && $_ ne 'index.html' } @mans;
			for (@mans) {
				s/\.html$//;
				$BotIrc::heap{man_cache}{$_} = undef;
			}
		}
		while ($_[ARG2] =~ /\bman\s+(git\s+)?([a-z-]+)?/g) {
			my $page = $2;
			if (defined $1) {
				$altpage = "git-$2";
				$page = $altpage if exists $BotIrc::heap{man_cache}{$altpage};
			}
			next if (!exists $BotIrc::heap{man_cache}{$page});
			BotIrc::send_wisdom("the $page manpage is available at $BotIrc::config->{man_baseurl}/$page.html");
		}
		return 0;
	},
};


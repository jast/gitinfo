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
			my $rpath = &BotIrc::return_path(@_) // return 0;
			return 1 if !BotIrc::noisy_command_authed($rpath, $source, $auth);

			umask(0022);
			system("cd $BotIrc::config->{man_repodir} && git pull -q &");
			BotIrc::msg_or_notice($rpath => "$source: manpage index updating. Please allow a few seconds before using again.");
			$BotIrc::heap{man_cache} = undef;
			return 1;
		}
	},
	irc_on_anymsg => sub {
		return 0 if ($_[ARG2] !~ /\bman\s+([a-z-]+)/);
		my $page = $1;
		my $rpath = &BotIrc::return_path(@_[ARG0, ARG1]) // return 0;
		my $nick = BotIrc::nickonly($_[ARG0]);

		if (!defined $BotIrc::heap{man_cache}) {
			my @mans = BotIrc::read_dir($BotIrc::config->{man_repodir}) or do {
				error("Manpage cache broken: $!");
				BotIrc::msg_or_notice($rpath => "$nick: manpage cache is broken. The bot owner has been notified.");
				return 1;
			};
			@mans = grep { $_ =~ /\.html$/ && $_ ne 'index.html' } @mans;
			for (@mans) {
				s/\.html$//;
				$BotIrc::heap{man_cache}{$_} = undef;
			}
		}
		if ($_[ARG2] =~ /\bman\s+git\s+([a-z-]+)/) {
			$altpage = "git-$1";
			$page = $altpage if exists $BotIrc::heap{man_cache}{$altpage};
		}
		return 0 if (!exists $BotIrc::heap{man_cache}{$page});
		my $recp = "";
		if ($_[ARG2] =~ /^([a-z_\[\]\{\}\\\|][a-z0-9_\[\]\\\|`^{}-]+)[,:]\s+/i) {
			$recp = "$1: ";
		}
		my $target = ($recp eq '' ? $rpath : $BotIrc::config->{channel});
		BotIrc::msg_or_notice($target => "${recp}the $page manpage is available at $BotIrc::config->{man_baseurl}/$page.html");
		return 1;
	},
};


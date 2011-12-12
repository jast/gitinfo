use POE;
{
	on_load => sub {
		$BotIrc::heap->{man_cache} = undef;
	},
	irc_commands => {
		man_update => sub {
			my ($source, $targets, $args, $auth) = @_;
			return 0 if !BotIrc::public_check_target($targets);
			return 1 if !BotIrc::public_command_authed($source, $auth);

			umask(0022);
			system("cd $BotIrc::config->{man_repodir} && git pull -q &");
			$BotIrc::irc->yield(privmsg => $BotIrc::config->{channel} => "$source: manpage index updating. Please allow a few seconds before using again.");
			$BotIrc::heap->{man_cache} = undef;
			return 1;
		}
	},
	irc_on_public => sub {
		return 0 if ($_[ARG2] !~ /\bman\s+([a-z-]+)(?:$|\s)/);
		my $nick = BotIrc::nickonly($_[ARG0]);
		my $page = $1;

		if (!defined $BotIrc::heap->{man_cache}) {
			my @mans = BotIrc::read_dir($BotIrc::config->{man_repodir}) or do {
				error("Manpage cache broken: $!");
				$BotIrc::irc->yield(privmsg => $BotIrc::config->{channel} => "$nick: manpage cache is broken. $BotIrc::config->{superadmin} has been notified.");
				return 1;
			};
			@mans = grep { $_ =~ /\.html$/ && $_ ne 'index.html' } @mans;
			for (@mans) {
				s/\.html$//;
				$BotIrc::heap->{man_cache}{$_} = undef;
			}
		}
		if ($_[ARG2] =~ /\bman\s+git\s+([a-z-]+)(?:$|\s)/) {
			$altpage = "git-$1";
			$page = $altpage if exists $BotIrc::heap->{man_cache}{$altpage};
		}
		return 0 if (!exists $BotIrc::heap->{man_cache}{$page});
		my $recp = "";
		if ($_[ARG2] =~ /^([a-z_\[\]\{\}\\\|][a-z0-9_\[\]\\\|`^{}-]+)[,:]\s+/) {
			$recp = "$1: ";
		}
		$BotIrc::irc->yield(privmsg => $BotIrc::config->{channel} => "${recp}the $page manpage is available at $BotIrc::config->{man_baseurl}/$page.html");
		return 1;
	},
};


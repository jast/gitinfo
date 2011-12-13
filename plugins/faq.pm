use POE;
{
	on_load => sub {
		$BotIrc::heap->{faq_cache} = undef;
		$BotIrc::heap->{faq_cacheupdate} = sub {
			return 1 if defined $BotIrc::heap->{faq_cache};
			my $error = shift || sub {};
			my $faq = BotIrc::read_file($BotIrc::config->{faq_cachefile}) or do {
				BotIrc::error("FAQ cache broken: $!");
				$error->("FAQ cache is broken. The bot owner has been notified.");
				return 0;
			};
			while ($faq =~ /<span id="([a-z-]+)" title="(.*?)">/g) {
				$BotIrc::heap->{faq_cache}{$1} = $2;
			}
			return 1;
		};
	},
	before_unload => sub {
		delete $BotIrc::heap->{faq_cache};
	},
	control_commands => {
		faq_list => sub {
			my ($client, $data, @args) = @_;
			$BotIrc::heap->{faq_cacheupdate}(sub { send($client, "error", "faqcache_broken", $_); }) or return;
			BotCtl::send($client, "ok", to_json($BotIrc::heap->{faq_cache}, {utf8 => 1, canonical => 1}));
		},
	},
	irc_commands => {
		faq_update => sub {
			my ($source, $targets, $args, $auth) = @_;
			my $rpath = &BotIrc::return_path(@_) // return 0;
			return 1 if !BotIrc::public_command_authed($source, $auth);

			system("wget --no-check-certificate -q -O '$BotIrc::config->{faq_cachefile}' '$BotIrc::config->{faq_geturl}' &");
			BotIrc::msg_or_notice($rpath => "$source: FAQ is updating. Please allow a few seconds before using again.");
			$BotIrc::heap->{faq_cache} = undef;
			return 1;
		}
	},
	irc_on_anymsg => sub {
		return 0 if ($_[ARG2] !~ /\bfaq\s+([a-z-]+)/);
		my $page = $1;
		my $rpath = &BotIrc::return_path(@_[ARG0, ARG1]) // return 0;
		my $nick = BotIrc::nickonly($_[ARG0]);

		$BotIrc::heap->{faq_cacheupdate}(sub { BotIrc::msg_or_notice($rpath => "$nick: ".$_); }) or return 1;
		return 1 if (!exists $BotIrc::heap->{faq_cache}{$page});
		my $info = $BotIrc::heap->{faq_cache}{$page};
		if ($info) {
			$info .= "; more details available at";
		} else {
			$info = "please see the FAQ page at";
		}
		my $recp = "";
		if ($_[ARG2] =~ /^([a-z_\[\]\{\}\\\|][a-z0-9_\[\]\\\|`^{}-]+)[,:]\s+/) {
			$recp = "$1: ";
		}
		my $target = ($recp eq '' ? $rpath : $BotIrc::config->{channel});
		BotIrc::msg_or_notice($target => "${recp}$info $BotIrc::config->{faq_baseurl}#$page");
		return 1;
	},
};

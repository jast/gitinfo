use POE;
{
	on_load => sub {
		$BotIrc::heap{faq_cache} = undef;
		$BotIrc::heap{faq_cacheupdate} = sub {
			return 1 if defined $BotIrc::heap{faq_cache};
			my $error = shift || sub {};
			my $faq = BotIrc::read_file($BotIrc::config->{faq_cachefile}) or do {
				BotIrc::error("FAQ cache broken: $!");
				$error->("FAQ cache is broken. The bot owner has been notified.");
				return 0;
			};
			while ($faq =~ /<span id="([a-z-]+)" title="(.*?)">/g) {
				$BotIrc::heap{faq_cache}{$1} = $2;
			}
			return 1;
		};
	},
	before_unload => sub {
		delete $BotIrc::heap{faq_cache};
	},
	control_commands => {
		faq_list => sub {
			my ($client, $data, @args) = @_;
			$BotIrc::heap{faq_cacheupdate}(sub { send($client, "error", "faqcache_broken", $_); }) or return;
			BotCtl::send($client, "ok", to_json($BotIrc::heap{faq_cache}, {utf8 => 1, canonical => 1}));
		},
	},
	irc_commands => {
		faq_update => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx(authed => 1) or return;

			system("wget --no-check-certificate -q -O '$BotIrc::config->{faq_cachefile}' '$BotIrc::config->{faq_geturl}' &");
			BotIrc::send_noise("FAQ is updating. Please allow a few seconds before using again.");
			$BotIrc::heap{faq_cache} = undef;
			return 1;
		}
	},
	irc_on_anymsg => sub {
		return 0 if ($_[ARG2] !~ /\bfaq\s+([a-z-]+)/);
		my $page = $1;
		BotIrc::check_ctx(wisdom_auto_redirect => 1) or return 0;

		$BotIrc::heap{faq_cacheupdate}(sub { BotIrc::msg_or_notice($rpath => "$nick: ".$_); }) or return 1;
		return 1 if (!exists $BotIrc::heap{faq_cache}{$page});

		my $info = $BotIrc::heap{faq_cache}{$page};
		if ($info) {
			$info .= "; more details available at";
		} else {
			$info = "please see the FAQ page at";
		}
		BotIrc::send_wisdom("$info $BotIrc::config->{faq_baseurl}#$page");
		return 1;
	},
};

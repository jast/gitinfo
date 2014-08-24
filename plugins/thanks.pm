use POE;
my %karma = ();

my $moar_karma = sub {
	my $n = shift;
	$karma{$n} //= 0;
	$karma{$n}++;
};

my $unhilite = sub {
	my $n = shift;
	substr($n, 1, 0) = "\xE2\x80\x8D"; # U+200D ZERO WIDTH JOINER
	# XXX- need to port to Unicode strings to get rid of this atrocity
	$n;
};

{
	schemata => {
		0 => [
			"CREATE TABLE thanks (from_nick TEXT NOT NULL, to_nick TEXT NOT NULL,
				created_at INT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
			"CREATE INDEX thanks_to_idx ON thanks (to_nick)",
			"CREATE INDEX thanks_from_idx ON thanks (from_nick)",
			"CREATE INDEX thanks_time_idx ON thanks (created_at)",
		],
	},
	on_load => sub {
		my $res = $BotDb::db->selectall_arrayref("SELECT * FROM thanks", {Slice => {}});
		$moar_karma->($_->{to_nick}) for @$res;
	},
	irc_commands => {
		karma => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return;

			my @args = map(lc, split(/\s+/, $args));
			@args = lc(BotIrc::ctx_source()) if !@args || !$args[0];
			my $placeholders = join(',', map {; '?' } @args);

			my $d30 = $BotDb::db->selectall_hashref("SELECT to_nick, CAST(count(to_nick)/10 AS INTEGER) AS nicksum FROM thanks WHERE to_nick IN ($placeholders) AND created_at > date('now','-30 day') GROUP BY to_nick", 'to_nick', {}, @args);
			my $given = $BotDb::db->selectall_hashref("SELECT from_nick, CAST(count(from_nick)/10 AS INTEGER) AS nicksum FROM thanks WHERE from_nick IN ($placeholders) GROUP BY from_nick", 'from_nick', {}, @args);

			my @karma = ();
			for my $n (@args) {
				next if (!exists $karma{$n});
				my $k = int($karma{$n}/10);
				next if !$k;
				my $n_escaped = $unhilite->($n);
				my $info = "$n_escaped: $k";
				$info .= " ($d30->{$n}{nicksum} in past 30 days)" if exists $d30->{$n};
				$info .= " ($given->{$n}{nicksum} given out)" if exists $given->{$n};
				push @karma, $info;
			}
			if (!@karma) {
				BotIrc::send_wisdom("the karma of the given users is shrouded in the mists of uncertainty.");
				return;
			}
			BotIrc::send_wisdom("the Genuine Real Life Karma™ REST API results are back! ". join(',  ', @karma));
		},
		topkarma => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx() or return;

			my $all = ($args =~ /^all$/);
			my $all_filter = $all ? "" : " WHERE created_at > date('now','-30 day')";
			my $res = $BotDb::db->selectall_arrayref("SELECT to_nick, count(to_nick) AS nicksum FROM thanks$all_filter GROUP BY to_nick ORDER BY nicksum DESC LIMIT 5", {Slice => {}});
			if (!ref($res) || @$res < 5) {
				BotIrc::send_noise("not enough data for a top karma list");
				return;
			}
			splice @$res, 5;
			my @top = map { $unhilite->($_->{to_nick}) .": ". int($_->{nicksum}/10) } @$res;

			my $all_msg = $all ? "of all time" : "of past 30 days ('all' arg to see totals)";
			BotIrc::send_wisdom("top karmic beings $all_msg: ". join(',  ', @top));
		}
	},
	irc_on_public => sub {
		BotIrc::check_ctx() or return 1;
		my $suffix_form = qr/\b/;
		my $is_suffix;
		if ($_[ARG2] =~ /\+\+/) {
			$suffix_form = qr/\+\+/;
			$is_suffix = 1;
		} else {
			return 0 if $_[ARG2] !~ /\b(?:thank\s*you|thanks|thx|cheers)\b/i;
		}

		my $ctx = BotIrc::ctx_frozen();
		my @nicks = map(lc, $BotIrc::irc->channel_list($ctx->{channel}));
		@nicks = grep { $_[ARG2] =~ /\b\Q$_\E$suffix_form/i; } @nicks;

		for my $n (@nicks) {
			next if $n eq lc(BotIrc::ctx_source());
			if ($n eq lc($BotIrc::irc->nick_name())) {
				BotIrc::ctx_set_addressee(BotIrc::ctx_source());
				if ($is_suffix) {
					BotIrc::send_wisdom("as a bot, I live on a higher plane of existence than you do. Karma has no meaning here.");
				} else {
					BotIrc::send_wisdom("you're welcome, but please note that I'm a bot. I'm not programmed to care.");
				}
			}
			$moar_karma->($n);
			$BotDb::db->do("INSERT INTO thanks (from_nick, to_nick) VALUES(?, ?)", {}, lc(BotIrc::ctx_source()), $n);
		}

		return 1;
	},
};

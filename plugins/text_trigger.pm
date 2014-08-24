use Encode;
use JSON;
use POE;
my %cache = ();
my $find_trigger = sub {
	my $query = shift;

	return ($query, $cache{$query}) if (defined $cache{$query});
	my @matches = grep(/\Q$query\E/, keys %cache);
	return undef if (!@matches);
	@matches = sort { length($a) <=> length($b) } @matches;

	# We don't want to do partial matches for very short queries
	return undef if ($matches[0] ne $query && length($query) < 3);

	return ($matches[0], $cache{$matches[0]});
};
my $cache_entry = sub {
	if (!defined $_[1]) {
		delete $cache{$_[0]};
	} else {
		$cache{$_[0]} = $_[1];
	}
};
my %last;
# Ugly recoding hack to work around double encoding somehow caused by Perl+JSON
my $json_encode = sub {
	encode('iso-8859-1', to_json(shift, {canonical => 1}));
};
{
	schemata => {
		0 => [
			"CREATE TABLE tt_triggers (trigger TEXT NOT NULL,
				lock INTEGER NOT NULL DEFAULT 0)",
			"CREATE TABLE tt_trigger_contents (tc_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
				trigger TEXT NOT NULL,
				exp TEXT NOT NULL,
				approved INT NOT NULL DEFAULT 1,
				changed_by TEXT NOT NULL,
				changed_at INT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
		],
		1 => [
			"ALTER TABLE tt_triggers ADD COLUMN
				deleted INTEGER NOT NULL DEFAULT 0"
		],
	},
	on_load => sub {
		my $res = $BotDb::db->selectall_arrayref("SELECT trigger, exp FROM tt_trigger_contents WHERE approved=1 ORDER BY changed_at DESC", {Slice => {}});
		for (@$res) {
			next if (exists $cache{$_->{trigger}});
			$cache_entry->($_->{trigger}, $_->{exp});
		}
	},
	control_commands => {
		trigger_list => sub {
			my ($client, $data, @args) = @_;
			BotCtl::send($client, "ok", $json_encode->(\%cache));
		},
		trigger_history => sub {
			my ($client, $data, @args) = @_;
			my $res = $BotDb::db->selectall_arrayref("SELECT tc_id, exp, changed_by, changed_at FROM tt_triggers NATURAL JOIN tt_trigger_contents WHERE approved=1 AND trigger=? ORDER BY changed_at DESC", {Slice => {}}, $args[0]);
			BotCtl::send($client, "ok", $json_encode->($res));
		},
		trigger_recentchanges => sub {
			my ($client, $data, @args) = @_;
			my $res = $BotDb::db->selectall_arrayref("SELECT trigger, exp, changed_by, changed_at FROM tt_triggers NATURAL JOIN tt_trigger_contents WHERE approved=1 AND deleted=0 ORDER BY changed_at DESC LIMIT 20", {Slice => {}});
			BotCtl::send($client, "ok", $json_encode->($res));
		},
		trigger_edit => sub {
			my ($client, $data, @args) = @_;
			&BotCtl::require_user or return;
			if (BotDb::has_priv($data->{level}, 'no_trigger_edit')) {
				BotCtl::send($client, "denied");
				return;
			}
			my $res = $BotDb::db->selectrow_hashref("SELECT * FROM tt_triggers WHERE trigger=?", {}, $args[0]);
			if (!defined $res) {
				if (defined $BotDb::db->err) {
					BotCtl::send($client, "error", "db_error", $BotDb::db->errstr);
					BotIrc::error("text_trigger: fetching trigger info for $args[0]: $BotDb::db->errstr");
				return;
				}
				BotCtl::send($client, "doesntexist");
				return;
			}
			if ($res->{lock} && !BotDb::has_priv($data->{level}, 'trigger_edit_locked')) {
				BotCtl::send($client, "locked");
				return;
			}
			$BotDb::db->do("INSERT INTO tt_trigger_contents (trigger, exp, changed_by) VALUES(?, ?, ?)", {}, $args[0], $args[1], $data->{level});
			if ($res->{deleted}) {
				$BotDb::db->do("UPDATE tt_triggers SET deleted = 0 WHERE trigger=?", {}, $res->{trigger});
			}
			$cache_entry->($args[0], $args[1]);
			BotCtl::send($client, "ok");
		},
		trigger_revert => sub {
			my ($client, $data, @args) = @_;
			&BotCtl::require_user or return;
			if (BotDb::has_priv($data->{level}, 'no_trigger_edit')) {
				BotCtl::send($client, "denied");
			}
			my $res = $BotDb::db->selectrow_hashref("SELECT * FROM tt_triggers NATURAL JOIN tt_trigger_contents WHERE tc_id=?", {}, $args[0]);
			if (!defined $res) {
				if (defined $BotDb::db->err) {
					BotCtl::send($client, "error", "db_error", $BotDb::db->errstr);
					BotIrc::error("text_trigger: fetching trigger info for $args[0]: $BotDb::db->errstr");
				return;
				}
				BotCtl::send($client, "doesntexist");
				return;
			}
			if ($res->{lock} && !BotDb::has_priv($data->{level}, 'trigger_edit_locked')) {
				BotCtl::send($client, "locked");
				return;
			}
			$BotDb::db->do("INSERT INTO tt_trigger_contents (trigger, exp, changed_by) VALUES(?, ?, ?)", {}, $res->{trigger}, $res->{exp}, $data->{level});
			if ($res->{deleted}) {
				$BotDb::db->do("UPDATE tt_triggers SET deleted = 0 WHERE trigger=?", {}, $res->{trigger});
			}
			$cache_entry->($res->{trigger}, $res->{exp});
			BotCtl::send($client, "ok");
		}
	},
	irc_commands => {
		trigger_edit => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx(authed => 1) or return;

			my ($trigger, $exp) = split(/\s+/, $args, 2);
			if (!$trigger || !$exp) {
				BotIrc::send_noise("Syntax: .trigger_edit <name> <contents>");
				return 1;
			}
			if ($trigger =~ /[^a-z0-9_.-]/i) {
				BotIrc::send_noise("Valid trigger names must consist of [a-zA-Z0-9_.-]");
				return 1;
			}
			BotIrc::check_ctx(antipriv => 'no_trigger_edit') or return;
			my $res = $BotDb::db->selectrow_hashref("SELECT * FROM tt_triggers WHERE trigger=?", {}, $trigger);
			if (!defined $res) {
				if (defined $BotDb::db->err) {
					BotIrc::send_noise("Uh-oh... something went wrong. Maybe this helps: $BotDb::db->errstr");
					BotIrc::error("text_trigger: fetching trigger info for $trigger: $BotDb::db->errstr");
					return 1;
				}
				# New trigger!
				BotIrc::check_ctx(priv => 'trigger_add') or return;
				$BotDb::db->do("INSERT INTO tt_triggers (trigger) VALUES(?)", {}, $trigger);
			}
			if ($res->{lock}) {
				BotIrc::check_ctx(priv => 'trigger_edit_locked') or return;
			}

			if ($exp eq '-') {
				BotIrc::check_ctx(priv => 'trigger_delete') or return;
				$BotDb::db->do("UPDATE tt_triggers SET deleted = 1 WHERE trigger=?", {}, $trigger);
				$cache_entry->($trigger, undef);
			} else {
				$BotDb::db->do("INSERT INTO tt_trigger_contents (trigger, exp, changed_by) VALUES(?, ?, ?)", {}, $trigger, $exp, $source);
				if ($res->{deleted}) {
					$BotDb::db->do("UPDATE tt_triggers SET deleted = 0 WHERE trigger=?", {}, $res->{trigger});
				}
				$cache_entry->($trigger, $exp);
			}
			BotIrc::send_noise("Okay.");
		}
	},
	irc_on_anymsg => sub {
		BotIrc::check_ctx(wisdom_auto_redirect => 1) or return 1;

		TRIGGERS: while ($_[ARG2] =~ /(?:^|[\s(){}\[\]])!([a-z0-9_.-]+)(\@[p*])?/ig) {
			my $query = $1;
			my $as_private = $2;
			my ($trigger, $exp);
			# This construct keeps removing trailing dots until a
			# match is found (or no further dots can be removed).
			# This is done so that punctuation can run into trigger
			# names without causing problems.
			while (1) {
				($trigger, $exp) = $find_trigger->($query);
				last if (defined $trigger);
				next TRIGGERS if (!($query =~ s/\.$//));
			}

			if ($exp =~ /^\@!([a-z_.-]+)$/i) {
				($trigger, $exp) = $find_trigger->($1);
			}
			next if $exp =~ m(^\@/dev/null(?:\s+\(.*\)|)$);
			next if !defined $trigger;

			my $trigger_exp = "";
			$trigger_exp = "[!$trigger] " if $trigger ne $query;
			BotIrc::ctx_set_addressee(undef) if defined $as_private && $as_private =~ /\*/;

			BotIrc::ctx_redirect_to_addressee() if defined $as_private && $as_private =~ /p/;

			# Squelch duplicate messages
			my $target = BotIrc::ctx_target('wisdom');
			my $last = $last{$target};
			next if $last && $last->[0] eq $trigger && (time < ($last->[1]+10));
			$last{$target} = [$trigger, scalar time];
			BotIrc::info("added last info: ".$json_encode->($last{$target}));

			BotIrc::send_wisdom("$trigger_exp$exp");
		}
		return 0;
	},
};

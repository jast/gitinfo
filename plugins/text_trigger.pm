use JSON;
use POE;
my %cache = ();
my $find_trigger = sub {
	my $query = shift;

	return ($query, $cache{$query}) if (defined $cache{$query});
	my @matches = grep(/\Q$query\E/, keys %cache);
	return undef if (!@matches);
	@matches = sort { length($a) <=> length($b) } @matches;
	return ($matches[0], $cache{$matches[0]});
};
my $cache_entry = sub {
	$cache{$_[0]} = $_[1];
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
			BotCtl::send($client, "ok", to_json(\%cache, {utf8 => 1, canonical => 1}));
		},
		trigger_history => sub {
			my ($client, $data, @args) = @_;
			my $res = $BotDb::db->selectall_arrayref("SELECT tc_id, exp, changed_by, changed_at FROM tt_triggers NATURAL JOIN tt_trigger_contents WHERE approved=1 AND trigger=? ORDER BY changed_at DESC", {Slice => {}}, $args[0]);
			BotCtl::send($client, "ok", to_json($res, {utf8 => 1, canonical => 1}));
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
			$cache_entry->($res->{trigger}, $res->{exp});
			BotCtl::send($client, "ok");
		}
	},
	irc_commands => {
		trigger_edit => sub {
			my ($source, $targets, $args, $auth) = @_;
			my $rpath = &BotIrc::return_path(@_) // return 0;
			return 1 if !BotIrc::public_command_authed($source, $auth);

			my ($trigger, $exp) = split(/\s+/, $args, 2);
			if (!$trigger || !$exp) {
				BotIrc::msg_or_notice($rpath => "$source: syntax: .trigger_edit <name> <contents>");
				return 1;
			}
			if ($trigger =~ /[^a-z_-]/i) {
				BotIrc::msg_or_notice($rpath => "$source: valid trigger names must consist of [a-zA-Z_-]");
				return 1;
			}
			return 1 if !BotIrc::public_check_antipriv($source, 'no_trigger_edit');
			my $res = $BotDb::db->selectrow_hashref("SELECT * FROM tt_triggers WHERE trigger=?", {}, $trigger);
			if (!defined $res) {
				if (defined $BotDb::db->err) {
					BotIrc::msg_or_notice($rpath => "$source: uh-oh... something went wrong. Maybe this helps: $BotDb::db->errstr");
					BotIrc::error("text_trigger: fetching trigger info for $trigger: $BotDb::db->errstr");
					return 1;
				}
				# New trigger!
				return 1 if !BotIrc::public_check_priv($source, 'trigger_add', $auth);
				$BotDb::db->do("INSERT INTO tt_triggers (trigger) VALUES(?)", {}, $trigger);
			}
			return 1 if ($res->{lock} && !BotIrc::public_check_priv($source, 'trigger_edit_locked', $auth));

			if ($exp eq '-') {
				return 1 if (!BotIrc::public_check_priv($source, 'trigger_delete', $auth));
				$BotDb::db->do("DELETE FROM tt_trigger_contents WHERE trigger=?", {}, $trigger);
				$BotDb::db->do("DELETE FROM tt_triggers WHERE trigger=?", {}, $trigger);
				$cache_entry->($trigger, undef);
			} else {
				$BotDb::db->do("INSERT INTO tt_trigger_contents (trigger, exp, changed_by) VALUES(?, ?, ?)", {}, $trigger, $exp, $source);
				$cache_entry->($trigger, $exp);
			}
			BotIrc::msg_or_notice($rpath => "$source: okay.");
		}
	},
	irc_on_anymsg => sub {
		my $rpath = &BotIrc::return_path(@_[ARG0, ARG1]) // return 0;
		return 0 if ($_[ARG2] !~ /(?:^|\s)!([a-z_-]+)/i);

		my $query = $1;
		my ($trigger, $exp) = $find_trigger->($query);
		return 0 if !defined $trigger;
		my $trigger_exp = "";
		$trigger_exp = "[!$trigger] " if $trigger ne $query;
		my $recp = "";
		if ($_[ARG2] =~ /^([a-z_\[\]\{\}\\\|][a-z0-9_\[\]\\\|`^{}-]+)[,:]\s+/i) {
			$recp = "$1: ";
		}
		my $target = ($recp eq '' ? $rpath : $BotIrc::config->{channel});
		BotIrc::msg_or_notice($target => "$recp$trigger_exp$exp");
		return 1;
	},
};

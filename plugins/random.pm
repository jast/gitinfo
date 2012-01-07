my @cache;
my @ids;
my $cache_items = sub {
	@cache = ();
	@ids = ();
	my $res = $BotDb::db->selectall_arrayref("SELECT rowid, random FROM random_stuff", {Slice => {}});
	for (@$res) {
		push @ids, $_->{rowid};
		push @cache, $_->{random};
	}
};
{
	schemata => {
		0 => [
			"CREATE TABLE random_stuff (random TEXT NOT NULL,
				added_by TEXT NOT NULL,
				added_at INT NOT NULL DEFAULT CURRENT_TIMESTAMP)",
		],
	},
	on_load => sub {
		$cache_items->();
	},
	irc_commands => {
		random => sub {
			my ($source, $targets, $args, $auth) = @_;
			my $rpath = &BotIrc::return_path // return 0;
			if (!$args) {
				my $i = int(rand(@cache));
				BotIrc::msg_or_notice($rpath => $cache[$i] ." [". $ids[$i] ."]");
				return 1;
			}
			return 1 if !BotIrc::public_command_authed($source, $auth);
			my ($cmd, $data) = split(/\s+/, $args, 2);
			if ($cmd eq 'add') {
				$BotDb::db->do("INSERT INTO random_stuff (random, added_by) VALUES(?, ?)", {}, $data, $source);
				$cache_items->();
				BotIrc::msg_or_notice($rpath => "$source: okay.");
			} elsif ($cmd eq 'rehash') {
				$cache_items->();
				BotIrc::msg_or_notice($rpath => "$source: okay.");
			} elsif ($cmd eq 'delete') {
				return 1 if (!BotIrc::public_check_priv($source, 'random_delete', $auth));
				$BotDb::db->do("DELETE FROM random_stuff WHERE rowid=?", $data);
				$cache_items->();
			}
		}
	},
};

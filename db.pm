package BotDb;
use common::sense;
use DBI;

our $db;

my $table_schemata = {
	# upgrade from 0 to 1: initial structure
	0 => [
		"CREATE TABLE users (username TEXT PRIMARY KEY NOT NULL,
			displayname TEXT,
			priv TEXT NOT NULL DEFAULT '')",
		"CREATE TABLE plugins (name TEXT PRIMARY KEY NOT NULL,
			version INT NOT NULL DEFAULT 0)",
		"CREATE TABLE settings (name TEXT PRIMARY KEY NOT NULL,
			value TEXT NOT NULL)",
	],
};

my @connect_pragmas = (
	"journal_mode = TRUNCATE", "locking_mode = EXCLUSIVE", "synchronous = OFF",
);

my %privs = ();

sub init() {
	$db = DBI->connect("dbi:SQLite:dbname=$BotIrc::config->{db_file}", "", "");
	update_schema();
}

sub update_schema($$$$) {
	my ($plugin, $schemata, $error, $info) = @_;
	$error //= \&BotIrc::error;
	$info //= \&BotIrc::info;
	my $version;

	if (!defined $plugin) {
		$version = $db->selectrow_array("PRAGMA user_version");
		$schemata = $table_schemata;
	} else {
		die("Code error: called update_schema with plugin $plugin but without schemata") if (!$schemata);
		$version = $db->selectrow_array("SELECT version FROM plugins WHERE name = ?", {}, $plugin);
	}
	$plugin //= 'core';

	SCHEMATA: while (exists $schemata->{$version}) {
		$info->("Upgrading database ($plugin) from v$version to v".($version+1).".");
		$db->begin_work;
		for my $s (@{$schemata->{$version}}) {
			if (!defined $db->do($s)) {
				$db->rollback;
				$error->("Error upgrading database ($plugin): ". $db->errstr);
				$error->("Query was: $s");
				return undef;
			}
		}
		$version++;
		if ($plugin eq 'core') {
			$db->do("PRAGMA user_version=$version");
		} else {
			$db->do("UPDATE plugins SET version = ? WHERE name = ?", {}, $version, $plugin);
		}
		$db->commit;
	}
	return 1;
}

# USER ACTIONS {{{ ###########################################################

sub _fetch_privs($) {
	my $nick = lc(shift);
	return 1 if (exists $privs{$nick});
	my $priv = $db->selectrow_array("SELECT priv FROM users WHERE username = ?", {}, $nick);
	if (!defined $priv) {
		if (defined $db->err) {
			BotIrc::error("Failed fetching privs for $nick: ".$db->errstr);
			return undef;
		}
		$priv = '';
	}
	my %p = ();
	foreach my $p (split(/,/, $priv)) {
		$p{$p} = 1;
	}
	$privs{$nick} = \%p;
	1;
}
sub _store_privs($) {
	my $nick = lc(shift);
	$db->do("UPDATE users SET priv=? WHERE username=?", {}, join(',', keys %{$privs{$nick}}), $nick);
}

sub is_superadmin($) {
	lc(shift) eq lc($BotIrc::config->{superadmin});
}

sub has_priv($$) {
	my ($nick, $priv) = map(lc, @_);
	if (is_superadmin($nick)) {
		return 0 if ($priv =~ /^no_/);
		return 1;
	}
	return 0 if (!_fetch_privs($nick));
	return exists($privs{$nick}{$priv});
}

sub add_priv($$) {
	my ($nick, $priv) = map(lc, @_);
	return 0 if (!_fetch_privs($nick));
	$privs{$nick}{$priv} = 1;
	_store_privs($nick);
}

sub del_priv($$) {
	my ($nick, $priv) = map(lc, @_);
	$privs{$nick} //= {};
	delete $privs{$nick}{$priv};
	_store_privs($nick);
}

# }}} ########################################################################

1;

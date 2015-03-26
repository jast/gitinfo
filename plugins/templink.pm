# Provides a facility for creating temporary shortened links.
# Plugins call this to generate a shortened link; a control client can
# retrieve the long URL given the keyword from the shortened one.
use POSIX;

my %links = ();
my $chars = '023456789abcdefghkmnopqrstuvwxyz';
my $numchars = length($chars);

my $int_to_str = sub {
	my $i = shift;
	my $res = '';
	while ($i > 0) {
		$res = substr($chars, $i % $numchars, 1) . $res;
		$i = POSIX::floor($i/$numchars);
	}
	$res;
};
my $str_to_int = sub {
	my $str = shift;
	my $i = 0;
	while (length($str)) {
		$i = $i * $numchars + index($chars, substr($str, 0, 1));
		$str = substr($str, 1);
	}
	$i;
};

{
	schemata => {
		0 => [
			"CREATE TABLE templinks (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
				url TEXT NOT NULL)",
		],
	},
	functions => {
		make => sub {
			my $url = shift;
			eval {
				$BotDb::db->do("INSERT INTO templinks (url) VALUES(?)", {}, $url);
			};
			if ($@) {
				return undef;
			}
			my $id = $BotDb::db->last_insert_id(undef, undef, "templinks", "id");
			my $tag = $int_to_str->($id);
			$links{$tag} = $url;
			return $BotIrc::config->{templink_baseurl} . $tag;
		},
	},
	control_commands => {
		'templink_get' => sub {
			my ($client, $data, @args) = @_;
			if (!exists $links{$args[0]}) {
				my $id = $str_to_int->($args[0]);
				my $res = $BotDb::db->selectrow_hashref(
					"SELECT url FROM templinks WHERE id = ?", {}, $id);
				if (!defined $res) {
					if (defined $BotDb::db->err) {
						BotCtl::send($client, "error", "db_error", $BotDb::db->errstr);
						BotIrc::error("templink: fetching link $args[0]=$id: ".$BotDb::db->errstr);
						return;
					}
					$client->put("error:notfound");
					return;
				}
				$links{$args[0]} = $res->{url};
			}
			BotCtl::send($client, "ok", $links{$args[0]});
		},
	},
	irc_commands => {
		'shorten' => sub {
			my ($source, $targets, $args, $auth) = @_;
			BotIrc::check_ctx(authed => 1) or return;
			my $nick = BotIrc::nickonly($source);
			my ($url) = split(/\s+/, $args);

			my $outurl = BotPlugin::call('templink', 'make', $args);
			BotIrc::send_noise(".shorten: out $outurl in $url");
		},
	},
};

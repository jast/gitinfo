# Provides a facility for creating temporary shortened links.
# Plugins call this to generate a shortened link; a control client can
# retrieve the long URL given the keyword from the shortened one.
use POSIX;

my %links = ();
my $id = 1;
my $chars = '23456789abcdefghjkmnpqrstuvwxyz';
my $numchars = length($chars);

my $int_to_str = sub {
	my $i = shift;
	my $res = '';
	while ($i > 0) {
		$res = $chars[$i % $numchars] . $res;
		$i = POSIX::floor($i/$numchars);
	}
	$res;
};

{
	functions => {
		make => sub {
			my $tag = $int_to_str->($id++);
			$links{$tag} = shift;
			return $tag;
		},
	},
	control_commands => {
		'templink_get' => sub {
			my ($client, $data, @args) = shift;
			if (!exists $links{$tag}) {
				$client->put("error:notfound");
				return;
			}
			BotCtl::send($client, "ok", $links{$tag});
		},
	},
};

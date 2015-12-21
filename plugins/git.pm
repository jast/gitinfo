use Encode;
use JSON;
use POE;

my $dolink = sub { BotPlugin::call('templink', 'make', shift); };
my %repo_providers = (
	github => {
		shortlog => "https://github.com/{key}/commits/{ref}",
		blob => "https://github.com/{key}/blob/{ref}/{path}",
		tree => "https://github.com/{key}/tree/{ref}/{path}",
		main => "https://github.com/{key}",
	},
	gitlab => {
		shortlog => "https://gitlab.com/{key}/commits/{ref}",
		blob => "https://gitlab.com/{key}/blob/{ref}/{path}",
		tree => "https://gitlab.com/{key}/tree/{ref}/{path}",
		main => "https://gitlab.com/{key}",
	},
	bitbucket => {
		shortlog => "https://bitbucket.org/{key}/commits/{ref}",
		blob => "https://bitbucket.org/{key}/src/{ref}/{path}",
		tree => "https://bitbucket.org/{key}/src/{ref}/{path}",
		main => "https://bitbucket.org/{key}",
	},
	kernel => {
		shortlog => "https://git.kernel.org/cgit/{key}.git/log/?h={ref}",
		blob => "https://git.kernel.org/cgit/{key}.git/tree/{path}?h={ref}",
		tree => "https://git.kernel.org/cgit/{key}.git/tree/{path}?h={ref}",
		main => "https://git.kernel.org/cgit/{key}.git",
	},
	repo => {
		shortlog => "http://repo.or.cz/w/{key}/shortlog/{ref}",
		blob => "http://repo.or.cz/w/{key}/blob/{ref}:/{path}",
		tree => "http://repo.or.cz/w/{key}/tree/{ref}:/{path}",
		main => "http://repo.or.cz/w/{key}",
	},
);

{
	irc_on_anymsg => sub {
		BotIrc::check_ctx(wisdom_auto_redirect => 1) or return 1;

		while ($_[ARG2] =~ /git:(\S+)/ig) {
			my $query = $1;
			$query =~ s/^"(.+)"$/$1/;
			my ($type, $key, $spec) = split(/:/, $query, 3);
			next unless exists $repo_providers{$type};

			my $prov = $repo_providers{$type};
			my $ref = 'HEAD';
			my $path;
			if ($spec =~ s/^([^:]*)://) {
				$ref = $1 unless $1 eq '';
			} elsif (defined $spec) {
				$ref = $spec;
				$path = []; # sticky undef
			} else {
				$ref = [];
				$path = [];
			}
			$path = $spec unless ref $path;
			undef $path if ref $path;

			my $mode = defined $path ? 'blob' : 'shortlog';
			$mode = 'tree' if defined $path && $path =~ m#(?:^|/)$#;
			$mode = 'main' if ref $ref;

			my $frag;
			($path, $frag) = split(/#/, ($path||''), 2);
			$frag ||= '';
			$frag = "#$frag" if $frag;

			my $url = $repo_providers{$type}{$mode};
			$url =~ s/\{key\}/$key/;
			$url =~ s/\{ref\}/$ref/;
			$url =~ s/\{path\}/$path/;

			BotIrc::send_wisdom("Git web link: $url$frag");
		}
		return 0;
	},
};

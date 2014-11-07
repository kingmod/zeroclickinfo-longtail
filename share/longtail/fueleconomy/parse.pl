#!/usr/bin/env perl

use Text::CSV_XS;
use URI::Escape;
#use Data::Dumper;

use strict;

# can be overridden on command-line
my $verbose = 0;
my $data = 'download/vehicles.csv.zip';
my $output_file = 'output.xml';

parse_argv();

my $csv = Text::CSV_XS->new() or
    die 'Cannot create Text::CSV_XS parser: ' . Text::CSV_XS->error_diag ();
open my $dfh, "unzip -cq $data |" or die "Failed to open $data: $?";

# wanted columns
my @wanted_cols = (qw'city08 highway08 cityA08 highwayA08 fuelType1 fuelType2', # fuel economy
	qw'year make model', # model
	qw'displ cylinders trany tCharger sCharger evMotor'); # configuration
my @spec_cols =	qw'fuelType drive trans_dscr eng_dscr VClass pv4 pv2 hpv lv4 lv2 hlv'; # specs

# Parse the source file and group all of the configurations for each year/make/model
my (%arts, %hdrs);
while(my $r = $csv->getline($dfh)){
    if(%hdrs){
		my ($city, $hwy, $city2, $hwy2, $ftype1, $ftype2, $yr, $make, $model,
			$displ, $cyl, $trany, $tc, $sc, $evm, @specs) = @$r[@hdrs{@wanted_cols, @spec_cols}]; 

        for ($make, $model, $evm, $trany){
            s/\s*\/\s*/\//g; # remove irregular spaces around alternate models with "/"
            tr/ //s; #remove duplicate spacing
        }

        my $vkey = join(' ', $yr, $make, $model);
		$vkey =~ s/[)(]/"/og;

		my $chksum = "$yr$make$model$displ$cyl$trany$tc$sc@specs";

		if(exists $arts{$vkey}{chksums}{$chksum}){
			warn "Duplicate line in CSV:\n\t@$r\n" if $verbose;
			next;
		}
		else{
			++$arts{$vkey}{chksums}{$chksum};
		}

        unless(exists $arts{$vkey}{src}){ # the search for the model
            $arts{$vkey}{src} = "http://www.fueleconomy.gov/feg/PowerSearch.do?action=noform&path=1&year1=$yr&year2=$yr&make="
                . uri_escape($make) . '&model=' . uri_escape($model) . '&srchtyp=ymm';
        }

        # basic model configuration info...unique *most* of the time
		my $vconfig = $ftype1 eq 'Electricity' ? $evm : "$displ L, $cyl cyl";
		if($trany){ $vconfig .= ", $trany"; } # some don't have transmissions listed, e.g. 2001 Hyper-Mini
        if($tc eq 'T'){ $vconfig .= ', Turbo'; }
        elsif($sc eq 'S'){ $vconfig .= ', Supercharger'; }

        # The site itself has duplicate descriptions, e.g. see the 1993 Chevy C1500.  Only drilling down
        # into the data further will you find that there is some distinguishing feature; for example,
        # the drive or transmission type.  The latter is probably unintelligible for the average 
        # consumer.  Anyhow, we'll carry these values forward for disambiguation if necessary.
		my $fe;
		if($ftype2){
			push @{$arts{$vkey}{city}}, $city2;
			push @{$arts{$vkey}{hwy}}, $hwy2;
			$fe = "$city city / $hwy hwy ($ftype1), $city2 city / $hwy2 hwy ($ftype2)";
		}
		else{
			$fe = "$city city / $hwy hwy";
		}
		push @{$arts{$vkey}{city}}, $city;
		push @{$arts{$vkey}{hwy}}, $hwy;
        push @{$arts{$vkey}{configs}{$vconfig}}, [$fe, @specs]; 
    }
    elsif($. == 1){
        for(my $i = 0;$i< @$r;++$i){
            $hdrs{$r->[$i]} = $i;
        }    

        my $verified_cols = 1;
        # verify the columns are there
		for my $h (@wanted_cols){
			unless(exists $hdrs{$h}){
				warn "Column $h not found";
				$verified_cols = 0;
			}
		}
        die 'Column headers seem to have changed. Verify manually' unless $verified_cols;
    }
    else{
        die 'Failed to extract headers';
    }
}

open my $output, ">$output_file" or die "Failed to open $output_file: $!";

print $output <<ENDOFXMLHDR;
<!-- This XML declaration can be simply copied and is necessary for all longtail. -->
<?xml version="1.0" encoding="UTF-8"?>
<add allowDups="true">
ENDOFXMLHDR

# Output the articles
while(my ($v, $data) = each %arts){
    my ($city, $hwy, $configs, $src) = @$data{qw(city hwy configs src)};
    my $summary;
    # Give city/hwy ranges for multiple configurations
    if((keys %$configs) > 1){ 
        my ($cmin, $cmax) = (sort {$a <=> $b} @$city)[0,-1];
        my ($hmin, $hmax) = (sort {$a <=> $b} @$hwy)[0,-1];
        if( ($cmin == $cmax) && ($hmin == $hmax) ){
            $summary = "$cmin city, $hmin hwy.";    
        }
        else{
            $summary = ($cmin != $cmax ? "$cmin-$cmax" : $cmin) . ' city, ' .
                       ($hmin != $hmax ? "$hmin-$hmax" : $hmin) . ' hwy depending on configuration.';
        }
    }
    else{ $summary = $city->[0] . ' city, ' . $hwy->[0] . ' hwy.' }
    my $rec = "MPG: $summary<br />";

    # add details for configurations
	my $add_vol_note;
    for my $config (sort keys %$configs){
        my $specs = $configs->{$config};
        my @display_configs;
        if(@$specs > 1){
			my $add_asterisk;
            SPEC: for(my $i = 1;$i < @{$specs->[0]};++$i){ # start at 1 to skip fuel economy value
                my %feature;
                for my $s (@$specs){
                    ++$feature{$s->[$i]};
                }    
                if( (keys %feature) > 1){ #feature is different for *some* configurations
					my $spec_col = $spec_cols[$i-1];
					if($spec_col =~ /^h?[pl]v[24]?$/o){
						++$add_asterisk;
						++$add_vol_note;
						unless(@display_configs){
							@display_configs = ($config) x scalar(@$specs);
						}
						next SPEC;
					}
                    for(my $s = 0;$s < @$specs;++$s){
						my $spec  = $specs->[$s][$i];
                        if(defined $display_configs[$s]){
                            $display_configs[$s] .= ", $spec";
                        }
                        else{
                            push @display_configs, "$config, $spec";
                        }
                    }    
                }
            }    
			unless(@display_configs){
				die qq{Vehicle "$v" has multiple configurations for "$config" with no distinguishing feature\n};
			}
			for(my $x = 0;$x < @display_configs;++$x){
				if($add_asterisk){
					$display_configs[$x] .= '*';
				}
				$display_configs[$x] .= ': ' . $specs->[$x][0];
			}
			# make sure this sort comes after config and fuel economy have been linked
            @display_configs = sort @display_configs;
        }
        else{
            @display_configs = ("$config: " . $specs->[0][0]);
        }
        for (@display_configs){
            $rec .= "<br />$_";
        }
    }
	if($add_vol_note){
		$rec .= '<br /><br />* Different passenger and/or luggage volumes';
	}
    print $output "\n", join("\n", 
		qq{<doc>}, 
		qq{<field name="title"><![CDATA[$v]]></field>},
		qq{<field name="paragraph"><![CDATA[$rec]]></field>},
		qq{<field name="paragraph"><![CDATA[$arts{$v}{src}]]></field>},
		qq{</doc>});
}

# command-line options
sub parse_argv {
    my $usage = <<ENDOFUSAGE;

    *******************************************************************
        USAGE: parse.pl [-data path/to/data] [-output path/to/output]
               [-v]

        -data: (optional) path to the downloaded zip file
        -output: (optional) path to output.txt file
        -v: (optional) Turn on some parse warnings

    *******************************************************************

ENDOFUSAGE

    for(my $i = 0;$i < @ARGV;$i++) {
        if($ARGV[$i] =~ /^-data$/o) { $data = $ARGV[++$i] }
        elsif($ARGV[$i] =~ /^-output$/o) { $output_file = $ARGV[++$i] }
        elsif($ARGV[$i] =~ /^-v$/o) { $verbose = 1; }
    }
}

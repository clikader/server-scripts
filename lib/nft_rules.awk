# Scope edits to one unambiguous allow rule in inet clikader_filter/input.
# Ignore braces and # characters inside quoted strings when tracking blocks.
function code_only(s,    i,c,out,quoted,escaped) {
    out=""; quoted=0; escaped=0
    for (i=1;i<=length(s);i++) {
        c=substr(s,i,1)
        if (escaped) { escaped=0; continue }
        if (quoted && c=="\\") { escaped=1; continue }
        if (c=="\"") { quoted=!quoted; continue }
        if (!quoted && c=="#") break
        if (!quoted) out=out c
    }
    return out
}
{
    code=code_only($0)
    if (depth==0 && code ~ /^[[:space:]]*table[[:space:]]+inet[[:space:]]+clikader_filter[[:space:]]*\{/) {
        table_depth=depth+1; in_table=1
    }
    if (in_table && depth==table_depth && code ~ /^[[:space:]]*chain[[:space:]]+input[[:space:]]*\{/) chain_depth=depth+1
    if (mode=="table" && in_table) print
    if (mode!="table" && in_table && chain_depth && depth==chain_depth &&
        code ~ /^[[:space:]]*(tcp|udp)[[:space:]]+dport[[:space:]]+\{[^}]*\}[[:space:]]+accept([[:space:]]|$)/) {
        protocol=code; sub(/^[[:space:]]*/,"",protocol); sub(/[[:space:]].*/,"",protocol)
        print NR "\t" protocol "\t" $0
    }
    opens=gsub(/\{/,"{",code); closes=gsub(/\}/,"}",code); depth+=opens-closes
    if (chain_depth && depth<chain_depth) chain_depth=0
    if (in_table && depth<table_depth) { in_table=0; table_depth=0 }
}

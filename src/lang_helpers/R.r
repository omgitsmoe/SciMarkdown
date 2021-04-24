# capture.output is the less explicit variant of this, but you have to
# put all of the code inside {} that are passed as argument to it
# capture.output({
#   print('hello')
#   print('goodbye')
# })
# actually not a vec of chars but a vec of vec of chars -> [][]const u8
stdout_buf <- vector('character')
stderr_buf <- vector('character')

write_to_con_with_length <- function(char_vec, connection) {
    # R doesn't support writing to stdout/err in binary mode so we have to use hacks
    # packing it as u8 and converting them to chars also doesn't work since it's
    # not supported afaik
    # in_bytes <- intToBits(sum(nchar(char_vec, type="bytes")))
    # write(packBits(in_bytes[1:8],   type="raw"), connection)
    in_bytes <- sum(nchar(char_vec, type="bytes"))
    # wow R doesn't support writing unsigned ints >2 bytes
    # WOW now we have to pass this as text
    # WOWOWOOWOWOWOOW write always prints a newline that you can't turn OFF even with sep=""
    # write is just a wrapper for cat() let's try that
    cat(paste0(in_bytes, ";"), connection, sep="", fill=F)
    # need fill otherwise []const u8 which are lines in this case (I assume) are not
    # printed on their own lines
    cat(paste0(char_vec, collapse="\n"), connection, sep="", fill=F)
}

out_tcon <- textConnection('stdout_buf', 'wr', local = TRUE)
err_tcon <- textConnection('stderr_buf', 'wr', local = TRUE)

# (default) type='output' -> diverts stdout
sink(out_tcon)
# type='message' -> diverts stderr including message, warning and stop
sink(err_tcon, type="message")

# --- setup end ---


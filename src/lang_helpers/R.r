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
    # add \n inserted by collapse; no \n after last element so decrement by 1
    #  + length(char_vec) - 1
    # even if i tell collapse to use \n it automatically uses \r\n!??!?!?!??!?!?!??!??!?!??!
    # NO actually collapse="\n" works correctly but cat just turns all \n into \r\n (on windows)
    # WOWOWOOWOWOOWOWOWOWOWOOWOWOWOOWOWOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOW
    collapsed <- paste0(char_vec, collapse="\n")
    in_bytes <- sum(nchar(collapsed, type="bytes"))
    # so now we have to count \n on windows and add that to in_bytes
    if (.Platform$OS.type == "windows") {
        in_bytes <- in_bytes + sum(charToRaw(collapsed) == charToRaw('\n'))
    }
    # wow R doesn't support writing unsigned ints >2 bytes
    # WOW now we have to pass this as text
    # WOWOWOOWOWOWOOW write always prints a newline that you can't turn OFF even with sep=""
    # write is just a wrapper for cat() let's try that
    # on the line below connection gets interpreted as another part of the varags
    # that should be printed -> stdout() is file descr one -> prints out 1
    # cat(paste0(in_bytes, ";"), connection, sep="", fill=F)
    cat(paste0(in_bytes, ";"), file=connection, sep="", fill=F)
    # need fill otherwise []const u8 which are lines in this case (I assume) are not
    # printed on their own lines -> or collapse them with paste
    # => \n have to be added to in_bytes
    cat(collapsed, file=connection, sep="", fill=F)
}

out_tcon <- textConnection('stdout_buf', 'wr', local = TRUE)
err_tcon <- textConnection('stderr_buf', 'wr', local = TRUE)

# (default) type='output' -> diverts stdout
sink(out_tcon)
# type='message' -> diverts stderr including message, warning and stop
sink(err_tcon, type="message")

# --- setup end ---


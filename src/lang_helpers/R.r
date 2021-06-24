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
    # R doesn't support writing to stdout/err in binary mode so we have to
    # use "text" mode
    # collapse="\n" works correctly but cat just turns all \n into \r\n (on windows)
    collapsed <- paste0(char_vec, collapse="\n")
    in_bytes <- sum(nchar(collapsed, type="bytes"))
    # so now we have to count \n on windows and add that to in_bytes
    if (.Platform$OS.type == "windows") {
        in_bytes <- in_bytes + sum(charToRaw(collapsed) == charToRaw('\n'))
    }

    cat(paste0(in_bytes, ";"), file=connection, sep="", fill=F)
    # need fill otherwise []const u8 which are lines in this case (I assume) are not
    # printed on their own lines -> or collapse them with paste
    cat(collapsed, file=connection, sep="", fill=F)
}

out_tcon <- textConnection('stdout_buf', 'wr', local = TRUE)
err_tcon <- textConnection('stderr_buf', 'wr', local = TRUE)

# (default) type='output' -> diverts stdout
sink(out_tcon)
# type='message' -> diverts stderr including message, warning and stop
sink(err_tcon, type="message")

# --- setup end ---


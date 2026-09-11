package logger

import "core:os"
import clog "core:log"

// Setup configures the process-wide logger to write to stderr so that stdout
// remains reserved for command output and language server messages.
//
// Call from the top of `main` and assign the result to `context.logger`:
//
//	context.logger = log.Setup()
Setup :: proc(lowest := clog.Level.Info) -> clog.Logger {
	return clog.create_file_logger(os.stderr, lowest=lowest)
}

debugf :: proc(fmt_str: string, args: ..any) { clog.debugf(fmt_str, ..args) }
infof  :: proc(fmt_str: string, args: ..any) { clog.infof(fmt_str, ..args) }
warnf  :: proc(fmt_str: string, args: ..any) { clog.warnf(fmt_str, ..args) }
errorf :: proc(fmt_str: string, args: ..any) { clog.errorf(fmt_str, ..args) }
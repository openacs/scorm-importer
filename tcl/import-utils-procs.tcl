ad_library {
    This provides an archive expander in the util namespace that should eventually
    probably go into acs-tcl.
}

namespace eval util {
    namespace eval archive {}
}

ad_proc -public util::archive::expand_file {
    upload_file
    tmpfile
    {dest_dir_base "extract"}
} {
    Given an uploaded file in file tmpfile with original name upload_file
    extract the archive and put in a tmp directory which is the return value
    of the function

    @param upload_file path to the uploaded file
    @param tmpfile temporary file name
    @option dest_dir_base name of the directory where the files will be extracted to
    @author Ernie Ghiglione (ErnieG@mm.st)

} {
    set tmp_dir [file join [file dirname $tmpfile] [ns_mktemp "$dest_dir_base-XXXXXX"]]
    if [catch { file mkdir $tmp_dir } errMsg ] {
        ns_log Notice "util::archive::expand_file: Error creating directory $tmp_dir: $errMsg"
        return -code error "util::archive::expand_file: Error creating directory $tmp_dir: $errMsg"
    }

    set upload_file [string trim [string tolower $upload_file]]

    if {[regexp {(.tar.gz|.tgz)$} $upload_file]} {
        set type tgz
    } elseif {[regexp {.tar.z$} $upload_file]} {
        set type tgZ
    } elseif {[regexp {.tar$} $upload_file]} {
        set type tar
    } elseif {[regexp {(.tar.bz2|.tbz2)$} $upload_file]} {
        set type tbz2
    } elseif {[regexp {.zip$} $upload_file]} {
        set type zip
    } else {
        set type "Unknown type"
    }

    switch $type {
        tar {
            set errp [ catch { exec tar --directory $tmp_dir -xvf $tmpfile } errMsg]

        } tgZ {
            set errp [ catch { exec tar --directory $tmp_dir -xZvf $tmpfile } errMsg]

        } tgz {
            set errp [ catch { exec tar --directory $tmp_dir -xzvf $tmpfile } errMsg]

        } tbz2 {
            set errp [ catch { exec tar --directory $tmp_dir -xjvf $tmpfile } errMsg]

        } zip {
            set errp [ catch { exec unzip -d $tmp_dir $tmpfile } errMsg]
            ## According to man unzip:
            # unzip exit status:
            #
            # 0      normal; no errors or warnings
            # detected.

            # 1 one or more warning errors were encountered, but process-
            #   ing  completed  successfully  anyway.  This includes zip-
            #   files where one or more files was skipped due  to  unsup-
            #   ported  compression  method or encryption with an unknown
            #   password.

            # Therefor it if it is 1, then it concluded successfully
            # but with warnings, so we switch it back to 0

            if {$errp == 1} {
                set errp 0
            }

        } default {
            set errp 1
            set errMsg " [_ lors.lt_dont_know_how_to_extr] $upload_file"
        }
    }

    if {$errp} {
        ::file delete -force -- $tmp_dir
        ns_log Notice "util::archive::expand_file: extract type $type failed $errMsg"
        return -code error "util::archive::expand_file: extract type $type failed $errMsg"
    }
    return $tmp_dir
}


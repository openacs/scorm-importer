ad_page_contract {

    Upload a SCORM 2004 course.

} {
    upload_file:trim,optional
    upload_file.tmpfile:optional,tmpfile
    online:boolean,notnull
    default_lesson_mode:notnull
    return_url:notnull
} -validate {
    non_empty -requires {upload_file.tmpfile:notnull} {
        if {![empty_string_p $upload_file] && \
                (![file exists ${upload_file.tmpfile}] || \
                [file size ${upload_file.tmpfile}] < 4)} {
            ad_complain "[_ lorsm.lt_The_upload_failed_or_]"
        }
    }
}

ad_progress_bar_begin \
    -title [_ scorm-importer.Uploading_Course] \
    -message_1 [_ scorm-importer.Uploading] \
    -message_2 [_ scorm-importer.Will_Continue]

# unzips the file
if { ![empty_string_p $upload_file] &&
    [catch {set tmp_dir [util::archive::expand_file \
                            $upload_file \
                            ${upload_file.tmpfile} \
                            lors-imscp-1] } errMsg] } {
    ad_return_complaint 1 "[_ scorm-importer.The_uploaded_file_doe]"
    ad_script_abort
}

if { [catch {scorm_importer::import \
                -package_id [ad_conn package_id] \
                -tmp_dir $tmp_dir \
                -online $online \
                -default_lesson_mode $default_lesson_mode} errMsg] } {
    ad_return_complaint 1 "[_ scorm-importer.Import_failed]: $errMsg"
    ad_script_abort
}

file delete -force $tmp_dir

ad_progress_bar_end -url $return_url

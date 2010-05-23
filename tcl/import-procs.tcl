ad_library {

}

namespace eval scorm_importer {
}

ad_proc scorm_importer::import {
    -tmp_dir:required
    -package_id:required
    {-online f}
    {-default_lesson_mode normal}
} {
    set up basic structure for content package
} {

    dom parse [::tDOM::xmlReadFile $tmp_dir/imsmanifest.xml] manifest

    db_transaction {
        # Now create the course from the manifest.
        set scorm_course_id [scorm_core::create_course \
            -package_id $package_id \
            -manifest $manifest \
            -online $online \
            -default_lesson_mode $default_lesson_mode]
    
        # Copy the files into the course folder in the content repository.
        scorm_importer::import_files \
            -dir $tmp_dir \
            -folder_id [scorm_core::get_folder -course_id $scorm_course_id] \
            -package_id $package_id
    }
}

ad_proc scorm_importer::import_files {
    -dir:required
    -folder_id:required
    -package_id:required
} {
    foreach file_name [glob -directory $dir *] {
        set cr_file_name [file tail $file_name]
        if { [file isdirectory $file_name] } {
            scorm_importer::import_files \
                 -dir $file_name \
                 -package_id $package_id \
                 -folder_id [scorm_core::create_folder \
                                -name $cr_file_name \
                                -parent_id $folder_id \
                                -package_id $package_id]
        } else {
            content::item::new \
                -name $cr_file_name \
                -parent_id $folder_id \
                -package_id $package_id \
                -tmp_filename $file_name \
                -mime_type [cr_filename_to_mime_type $file_name]
        }
    }
}


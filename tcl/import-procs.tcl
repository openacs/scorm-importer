ad_library {

}

namespace eval scorm_importer {
}

ad_proc scorm_importer::create_course {
    -package_id:required
    -manifest:required
    -folder_id:required
    {-course_id ""}
    {-online f}
    {-default_lesson_mode browse}
    {-course_type scorm_course}
} {
    Create a Scorm course skeleton based on a parsed manifest.
} {

    # Version check.  At the moment, it's scorm 2004 or or else it's an error.
    set metadata [[$manifest documentElement] child 1 metadata]
    set schemaversion [$metadata child 1 schemaversion]
    if { $schemaversion eq "" ||
         [string trim [string tolower [$schemaversion nodeValue]]] eq "adl scorm" &&
         [string trim [string tolower [$schemaversion nodeValue]]] eq "2004 3rd edition" } {
        return -code error [_ scorm-importer.NotSCORM2004]
    }

    set transform [scorm_importer::transform -manifest $manifest]
    set transform_doc [$transform documentElement]

    set organization_node [$transform_doc child all organization]
    set title [$organization_node getAttribute title ""]

    set var_list [subst {
        {folder_id $folder_id}
        {context_id $package_id}
        {type scorm2004}
        {online $online}
        {title "$title"}
        {object_type $course_type}
        {${course_type}_id $course_id}
        {default_lesson_mode $default_lesson_mode}
    }]
    set course_id [package_instantiate_object -var_list $var_list $course_type]

    # create row for package even though we don't have any info yet
    db_dml insert_package {}

    scorm_importer::update_rte_data \
        -scorm_course_id $course_id \
        -manifest $manifest \
        -transform_doc $transform_doc

    $transform delete
}

ad_proc scorm_importer::edit_course {
    -manifest:required
    -course_id:required
} {
    Edit the course information.
} {

    set transform [scorm_importer::transform -manifest $manifest]

    scorm_importer::update_rte_data \
        -scorm_course_id $scorm_course_id \
        -manifest $manifest \
        -transform_doc [$transform documentElement]

    $transform delete
}

ad_proc scorm_importer::update_rte_data {
    -scorm_course_id:required
    -manifest:required
    -transform_doc:required
} {
    Update the RTE data - activity tree, jsdata, xmldata
} {
    # build activity tree with the original document.
    array set adl_info \
        [scorm_importer::rte_activity_tree::create -manifest [$manifest documentElement]]

    set activity_tree $adl_info(activity_tree)
    set global_to_system [expr { [string is true $adl_info(global)] ? "t" : "f" }]

    import_node -cp_package_id $scorm_course_id -node $transform_doc
    set xmldata [$transform_doc asXML]

    set jsdata [scorm_importer::rte_jsdata::create -manifest $transform_doc]

    db_dml update_package {}

}

ad_proc scorm_importer::transform {
    -manifest:required
} {
    Transfrom the manifest using ilias's normalizing xsl.
} {
    set xsl_src "[acs_root_dir]/packages/scorm-importer/templates/xsl/op/op-scorm13.xsl"
    return [$manifest xslt [dom parse [::tDOM::xmlReadFile $xsl_src]]]
}

ad_proc scorm_importer::create_folder {
    -name:required
    -parent_id:required
    -package_id:required
} {
    Create a subr (or main) for a class with the necessary 
} {
    set folder_id [content::folder::new \
                      -name $name \
                      -parent_id $parent_id \
                      -package_id $package_id]

    content::folder::register_content_type \
        -folder_id $folder_id  \
        -content_type content_revision \
        -include_subtypes "t"

    content::folder::register_content_type \
        -folder_id $folder_id \
        -content_type content_item \
        -include_subtypes t

    return $folder_id
}

ad_proc scorm_importer::import {
    -tmp_dir:required
    -package_id:required
    {-online f}
    {-default_lesson_mode normal}
} {
    set up basic structure for content package
} {

    # Grab manifest from tmp_dir and parse.
    dom parse [::tDOM::xmlReadFile $tmp_dir/imsmanifest.xml] manifest

    # Create the target folder for the course import.

    # The name should be the tail of the file, with the UI guarding against uploading
    # dupe courses, with the admin UI giving the option to delete/update courses, of course.

    regexp {([^/\\]+)$} $tmp_dir match cr_dir
    regsub -all { +} $cr_dir {_} name

    set parent_folder_id [scorm_core::default_folder_id -package_id $package_id]
    set folder_id [scorm_importer::create_folder \
                      -name $name \
                      -parent_id $parent_folder_id \
                      -package_id $package_id]

    # Now create the course from the manifest.
    set scorm_course_id [scorm_importer::create_course \
        -package_id $package_id \
        -folder_id $folder_id \
        -manifest $manifest \
        -online $online \
        -default_lesson_mode $default_lesson_mode]
    $manifest delete

    # Copy the files into the course folder in the content repository.

    scorm_importer::import_files \
        -dir $tmp_dir \
        -folder_id $folder_id \
        -package_id $package_id

}

# This needs to be fixed to skip nodes that already exist, by selecting a unique node
# for the package using the attributes ...
ad_proc scorm_importer::import_node {
    {-node:required}
    {-cp_package_id:required}
    {-depth 1}
    {-parent 0}
} {
    Import a node and its children.

} {

    set nodename [$node nodeName]

    # create the node
    set cp_node_id [db_nextval cp_node_seq]
    set rgt $cp_node_id

    db_dml insert_cp_node {}

    # and insert into tree
    db_dml add_to_cp_tree {}

    # gather attributes for insertion, starting with cp_node_id
    set attributes [list cp_node_id]

    # from http://wiki.tcl.tk/1948
    # attributes may return a singleton. In that case, the attribute name is just that.

    # attributes may return a three-element list. In that case it may be approximated as:

    # [lassign $a name namespace uri]

    # however, the uri may be empty and the name and namespace equal. In that case, the
    # attribute appears to be a definition of the uri for the namespace given by $name,
    # although the uri thus defined is not returned in the uri field, the uri-defining
    #attribute is named as if it were $ns:$ns. Finally, the {xmlns {} {}} form appears
    #to be special, and to indicate that the xmlns namespace's uri is being defined. 

    # build up generic attribute list for insertion
    foreach attribute [$node attributes] {
        if { [llength $attribute] == 1 } {
            set _attribute [scorm_core::db_name -name [string tolower $attribute]]
            lappend attributes $_attribute
            set value [$node getAttribute $attribute]
            # convert trues/falses to t/f
            set $_attribute [ad_decode $value true t false f $value]
        } else {
            foreach { name namespace uri } $attribute { break }
            # ignore xmlns (the only trio not handled by transform?)
            if { $name eq "xmlns" } { continue }
            set _name [scorm_core::db_name -name [string tolower $name]]
            lappend attributes $_name
            set value [$node getAttribute $name $namespace]
            # convert trues/falses to t/f
            set $_name [ad_decode $value true t false f $value]
        }
    }

    # stick cp_node_id into DOM for use later
    $node setAttribute foreignId $cp_node_id

    # insert into cp_*
    db_dml insert_cp {}

    # run sub nodes
    foreach child [$node childNodes] {
        set rgt [import_node -node $child -cp_package_id $cp_package_id \
                    -depth [expr $depth + 1] -parent $cp_node_id]
    }

    db_dml update_rgt {}

    return $rgt
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
                 -folder_id [scorm_importer::create_folder \
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

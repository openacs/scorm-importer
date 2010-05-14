ad_library {

}

namespace eval scorm_importer {
}

ad_proc -public scorm_importer::create_course {
    -package_id:required
    -manifest:required
    -folder_id:required
    {-scorm_course_id ""}
    {-online f}
    {-default_lesson_mode browse}
    {-verbose_p 0}
} {
    Create a Scorm course skeleton based on a parsed manifest.
} {

    # build activity tree before we transform the document
    array set adl_info \
        [scorm_importer::rte_activity_tree::create \
            -manifest [$manifest documentElement] \
            -verbose_p $verbose_p]

    set activity_tree $adl_info(activity_tree)
    set global_to_system [expr { [string is true $adl_info(global)] ? "t" : "f" }]

    # transform scorm xml using ilias's normalizing xsl
    set xsl_src "[acs_root_dir]/packages/scorm-importer/templates/xsl/op/op-scorm13.xsl"
    dom parse [::tDOM::xmlReadFile $xsl_src] transform
    $manifest xslt $transform manifest
    set document_element [$manifest documentElement]

    set xmldata [$manifest asXML]
    set organization_node [$document_element child all organization]
    set title [$organization_node getAttribute title ""]

    set var_list [subst {
        {folder_id $folder_id}
        {context_id $package_id}
        {type scorm2004}
        {online $online}
        {title "$title"}
        {scorm_course_id $scorm_course_id}
        {default_lesson_mode $default_lesson_mode}
    }]
    set scorm_course_id [package_instantiate_object -var_list $var_list scorm_course]

    # create row for package even though we don't have any info yet
    db_dml insert_package {}

    import_manifest \
        -cp_package_id $scorm_course_id \
        -manifest $document_element \
        -verbose_p $verbose_p

    set jsdata [scorm_importer::rte_jsdata::create \
                   -manifest $document_element \
                   -verbose_p $verbose_p]

    db_dml update_package {}

    $transform delete
    $manifest delete

}

ad_proc scorm_importer::create_subfolder {
    -name:required
    -parent_id:required
    -package_id:required
} {
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

ad_proc -public scorm_importer::import {
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
    set folder_id [scorm_importer::create_subfolder \
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

    # Copy the files into the course folder in the content repository.

    scorm_importer::import_files \
        -dir $tmp_dir \
        -folder_id $folder_id \
        -package_id $package_id

}

ad_proc scorm_importer::import_manifest {
    -cp_package_id:required
    -manifest:required
    {-verbose_p 0}
} {
    build db structures for course
} {

    # set up lft as global so we can track children inside 
    # import_node and can update rgt
    global lft
    set lft 1

    # import all nodes, starting with root (manifest)
    import_node -node $manifest -cp_package_id $cp_package_id -verbose_p $verbose_p

}

ad_proc scorm_importer::import_node {
    {-node:required}
    {-cp_package_id:required}
    {-depth 1}
    {-parent 0}
    {-verbose_p 0}
} {
    Import given node
} {

    # bring in lft
    global lft

    set nodename [$node nodeName]
    if { $verbose_p } { ns_write "$nodename " }
    
    # create the node
    set cp_node_id [db_nextval cp_node_cp_node_id_seq]
    db_dml insert_cp_node {}

    # and insert into tree
    db_dml add_to_cp_tree {}

    # set up next child or, if none, rgt (see below)
    incr lft

    # gather attributes for insertion, starting with cp_node_id
    set attributes [list cp_node_id]

    # from http://wiki.tcl.tk/1948
    # attributes may return a singleton. In that case, the attribute name is just that.

    # attributes may return a three-element list. In that case it may be approximated as:

    # [lassign $a name namespace uri]

    # however, the uri may be empty and the name and namespace equal. In that case, the attribute appears
    # to be a definition of the uri for the namespace given by $name, although the uri thus defined is not 
    # returned in the uri field, the uri-defining attribute is named as if it were $ns:$ns. Finally, the 
    # {xmlns {} {}} form appears to be special, and to indicate that the xmlns namespace's uri is being defined. 

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
        import_node -node $child -cp_package_id $cp_package_id \
            -depth [expr $depth + 1] -parent $cp_node_id -verbose_p $verbose_p
    }

    # update cp_tree
    db_dml update_rgt {}

    # set up next child
    incr lft

    return
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
                 -folder_id [scorm_importer::create_subfolder \
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

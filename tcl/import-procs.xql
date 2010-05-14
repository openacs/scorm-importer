<?xml version="1.0"?>

<queryset>

    <fullquery name="scorm_importer::create_course.insert_package">
        <querytext>
          insert into cp_package (cp_package_id) values (:scorm_course_id)
        </querytext>
    </fullquery>

    <fullquery name="scorm_importer::create_course.update_package">
        <querytext>
          update cp_package
             set jsdata = :jsdata,
                 xmldata = :xmldata,
                 activitytree = :activity_tree,
                 global_to_system = :global_to_system
           where cp_package_id = :scorm_course_id
        </querytext>
    </fullquery>

    <fullquery name="scorm_importer::import_node.insert_cp_node">
        <querytext>
          insert into cp_node
          (cp_node_id, nodename, cp_package_id)
          values
          (:cp_node_id, :nodename, :cp_package_id)
        </querytext>
    </fullquery>

    <fullquery name="scorm_importer::import_node.add_to_cp_tree">
        <querytext>
          insert into cp_tree
          (child, depth, lft, cp_package_id, parent, rgt)
          values
          (:cp_node_id, :depth, :lft, :cp_package_id, :parent, '0')
        </querytext>
    </fullquery>

    <fullquery name="scorm_importer::import_node.insert_cp">
        <querytext>
          insert into cp_[string tolower ${nodename}]
          ([join $attributes ", "])
          values
          (:[join $attributes ", :"])
        </querytext>
    </fullquery>

    <fullquery name="scorm_importer::import_node.update_rgt">
        <querytext>
          update cp_tree set rgt = :lft where child = :cp_node_id
        </querytext>
    </fullquery>

</queryset>

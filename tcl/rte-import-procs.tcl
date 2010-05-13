ad_library {

}

namespace eval scorm_importer {
    namespace eval rte_jsdata {}
    namespace eval rte_activity_tree {}
}

ad_proc scorm_importer::rte_jsdata::create {
    -manifest:required
    {-verbose_p 0}
} {
    build course content jsdata structure in tcl and convert to JSON format for ilias RTE

    ported from ilias
} {

    # This should be in the parser, not the JSON generation code ???
    # first read resources into flat array to resolve item/identifierref later
    foreach resource [$manifest child all resource] {
        set resources([$resource getAttribute id]) $resource
    }

    # iterate through items and set href and scoType as activity attributes
    foreach item [$manifest selectNodes "//*\[local-name()=\"item\"\]"] {
        if { [$item hasAttribute resourceId] } {
            # get reference to resource and set href accordingly
            set resource $resources([$item getAttribute resourceId])
            #$item setAttribute href "[$resource getAttribute base] [$resource getAttribute href]"
            $item setAttribute href "[$resource getAttribute href]"
            $item removeAttribute resourceId
            if { [$resource getAttribute scormType] eq "sco" } {
                $item setAttribute sco 1
            }
        }
    }

    set organization_node [$manifest child all organization]

    $organization_node setAttribute base ""

    # We need to kludge the top level, renaming "organization" to "item" and pulling
    # the sequencing nodes into an array at the same level as the "item" structure.

    lappend jsdata item [scorm_importer::rte_jsdata::node -node $organization_node]

    set sequencing_nodes {}
    foreach sequencing_node [$manifest child all sequencing] {
        lappend sequencing_nodes [scorm_importer::rte_jsdata::node -node $sequencing_node]
    }
    lappend jsdata sequencing [util::json::array::create $sequencing_nodes]

    # extra stuff wanted by the RTE
    lappend jsdata foreignId [$manifest getAttribute foreignId]
    lappend jsdata id [$manifest getAttribute id]
    lappend jsdata base ""

    return [util::json::gen [util::json::object::create $jsdata]]
}

ad_proc scorm_importer::rte_jsdata::node {
    -node:required
} {
    build node
} {

    set node_list {}
    foreach attribute [$node attributes] {
        if { [llength $attribute] == 1 } {
            set value [$node getAttribute $attribute]
            lappend node_list $attribute $value
        }
    }

    # process the children

    # XML: list of nodes like <tag_a/><tag_a/><tag_b/><tag_b/>
    # JSON: {"tag_a":[{contents contents}], "tag_b":[{contents contents}]}

    # Since the children can in theory have different tags, we collect the tag names
    # and values in an array and then spit them out after parsing the children.

    # Parse children and collect them by tag name.
    foreach child [$node childNodes] {
        lappend child_nodes([$child nodeName]) [scorm_importer::rte_jsdata::node -node $child]
    }

    # Add them to our key/value node_list
    foreach child_name [array names child_nodes] {
        lappend node_list $child_name [util::json::array::create $child_nodes($child_name)]
    }

    return [util::json::object::create $node_list]
}

ad_proc scorm_importer::rte_activity_tree::create {
    -manifest:required
    {-verbose_p 0}
} {
    build activity tree structure in tcl and convert to JSON format for ilias RTE

    ported from ilias
} {

    global sequencing_collection
    set sequencing_collection [$manifest getElementsByTagName "imsss:sequencingCollection"]

    set organizations [$manifest child all organizations]
    set default [$organizations getAttribute default]
    foreach organization [$organizations child all organization] {
        if { [$organization getAttribute identifier] eq $default } {
            set default_org $organization
        }
    }

    set activity_tree [scorm_importer::rte_activity_tree::seq_activity -node $default_org -order -1]

    set adl_info(global) [$default_org getAttribute adlseq:objectivesGlobalToSystem true]
    set adl_info(activity_tree) [util::json::gen $activity_tree]
    return [array get adl_info]

}

ad_proc scorm_importer::rte_activity_tree::seq_activity {
    -node:required
    -order:required
} {
    global sequencing_collection

    array set activity [scorm_importer::rte_activity_tree::activity_attributes]
    if { [$node hasAttribute identifier] } {
        set activity(mActivityID) [$node getAttribute identifier]
    }

    if { [$node hasAttribute identifierref] } {
        set activity(mResourceID) [$node getAttribute identifierref]
    }

    if { [$node hasAttribute isvisible] } {
        set activity(mIsVisible) [convert_to_bool [$node getAttribute isvisible]]
    }

    set activity(mOrder) $order
    set activity(mActiveOrder) $order
    unset order

    set children [list]
    foreach child [$node childNodes] {
        switch -- [$child localName] {
            item {
                # store counter for child ordering in node
                if { [$node hasAttribute order] } {
                    set order [$node getAttribute order]
                    $node setAttribute order [incr order]
                } else {
                    set order 0
                    $node setAttribute order $order
                }
                lappend children \
                    [scorm_importer::rte_activity_tree::seq_activity -node $child -order $order]
            }
            title {
                set activity(mTitle) [$child text]
            }
            sequencing {
                if { [$child hasAttribute IDRef] } {
                    # this sequencing node references a base in the global collection
                    set id_ref [$child getAttribute IDRef]
                    set sequencings [$sequencing_collection getElementsByTagName "imsss:sequencing"]
                    foreach sequencing $sequencings {
                        if { [$sequencing getAttribute ID] eq $id_ref } {
                            # this is now our base
                            set composite_sequencing [$sequencing cloneNode -deep]
                            break
                        }
                    }
                    if { ![info exists composite_sequencing] } {
                        return -code error "Sequencing \"$id_ref\" not found in global collection."
                    }
                    foreach sequencing_child [$child childNodes] {
                        if { [$sequencing_child nodeType] eq "ELEMENT_NODE" } {
                            $composite_sequencing appendChild $sequencing_child
                        }
                    }
                    scorm_importer::rte_activity_tree::extract_sequencing_info \
                       -node $composite_sequencing \
                       -result activity
                } else {
                    # no global reference
                    scorm_importer::rte_activity_tree::extract_sequencing_info \
                       -node $child \
                       -result activity

                }
            }
        }
    }

    if { [llength $children] } {
        set activity(mChildren) [util::json::array::create $children]
        set activity(mActiveChildren) [util::json::array::create ""]
    } 

    # remove our counter
    if { [$node hasAttribute order] } {
        $node removeAttribute order
    } 

    return \
        [util::json::object::create \
            [list _SeqActivity \
                [util::json::object::create [array get activity]]]]

}

ad_proc scorm_importer::rte_activity_tree::extract_sequencing_info {
    -node:required
    -result:required
} {
    upvar $result local_result

    foreach child [$node childNodes] {
        if { [$child nodeType] eq "ELEMENT_NODE" } {
            switch [$child localName] {
                "objectives" {
                    scorm_importer::rte_activity_tree::get_objectives \
                        -node $child \
                        -result local_result
                }
                "sequencingRules" {
                    scorm_importer::rte_activity_tree::get_sequencing_rules \
                        -node $child \
                        -result local_result
                }
                "rollupRules" {
                    scorm_importer::rte_activity_tree::get_rollup_rules \
                        -node $child \
                        -result local_result
                }
                "auxiliaryResources" {
                    scorm_importer::rte_activity_tree::get_auxiliary_resources \
                        -node $child \
                        -result local_result
                }
                "controlMode" {
                    if { [$child hasAttribute choice] } {
                        set local_result(mControl_choice) \
                            [convert_to_bool [$child getAttribute choice]]
                    }
                    if { [$child hasAttribute choiceExit] } {
                        set local_result(mControl_choiceExit) \
                            [convert_to_bool [$child getAttribute choiceExit]]
                    }
                    if { [$child hasAttribute flow] } {
                        set local_result(mControl_flow) \
                            [convert_to_bool [$child getAttribute flow]]
                    }
                    if { [$child hasAttribute forwardOnly] } {
                        set local_result(mControl_forwardOnly) \
                            [convert_to_bool [$child getAttribute forwardOnly]]
                    }
                    if { [$child hasAttribute useCurrentAttemptObjectiveInfo] } {
                        set local_result(mUseCurObj) \
                            [convert_to_bool [$child getAttribute useCurrentAttemptObjectiveInfo]]
                    }
                    if { [$child hasAttribute useCurrentAttemptProgressInfo] } {
                        set local_result(mUseCurPro) \
                            [convert_to_bool [$child getAttribute useCurrentAttemptProgressInfo]]
                    }
                }
                "limitConditions" {
                    if { [$child hasAttribute attemptLimit] } {
                        set attempt_limit [$child getAttribute attemptLimit]
                        if { $attempt_limit >= 0 } {
                            set local_result(mMaxAttemptControl) true
                            set local_result(mMaxAttempt) $attempt_limit
                        } else {
                            set local_result(mMaxAttemptControl) false
                            set local_result(mMaxAttempt) -1
                        }
                    }
                    if { [$child hasAttribute attemptAbsoluteDurationLimit] } {
                        set duration [$child getAttribute attemptAbsoluteDurationLimit]
                        if { $duration ne "null" } {
                            set local_result(mActivityAbDurControl) true
                        } else {
                            set local_result(mActivityAbDurControl) false
                        }
                    }
                    if { [$child hasAttribute attemptExperiencedDurationLimit] } {
                        set duration [$child getAttribute attemptExperiencedDurationLimit]
                        if { $duration ne "null" } {
                            set local_result(mAttemptExDurControl) true
                        } else {
                            set local_result(mAttemptExDurControl) false
                        }
                    }
                    if { [$child hasAttribute activityAbsoluteDurationLimit] } {
                        set duration [$child getAttribute activityAbsoluteDurationLimit]
                        if { $duration ne "null" } {
                            set local_result(mActivityAbDurControl) true
                        } else {
                            set local_result(mActivityAbDurControl) false
                        }
                    }
                    if { [$child hasAttribute activityExperiencedDurationLimit] } {
                        set duration [$child getAttribute activityExperiencedDurationLimit]
                        if { $duration ne "null" } {
                            set local_result(mmActivityExDurControl) true
                        } else {
                            set local_result(mmActivityExDurControl) false
                        }
                    }
                    if { [$child hasAttribute beginTimeLimit] } {
                        set time [$child getAttribute beginTimeLimit]
                        if { $time ne "null" } {
                            set local_result(mBeginTimeControl) true
                            set local_result(mBeginTime) $time
                        } else {
                            set local_result(mBeginTimeControl) false
                        }
                    }
                    if { [$child hasAttribute endTimeLimit] } {
                        set time [$child getAttribute endTimeLimit]
                        if { $time ne "null" } {
                            set local_result(mEndTimeControl) true
                            set local_result(mEndTime) $time
                        } else {
                            set local_result(mEndTimeControl) false
                        }
                    }
                }
                "randomizationControls" {
                    if { [$child hasAttribute randomizationTiming] } {
                        set timing [$child getAttribute randomizationTiming]
                        # check vocabulary (according to ilias)
                        switch $timing {
                            onEachNewAttempt - once - never {
                                set local_result(mRandomTiming) $timing
                            }
                            default {
                                set local_result(mSelectTiming) never
                            }
                        }
                    }
                    if { [$child hasAttribute selectCount] } {
                        set count [$child getAttribute selectCount]
                        if { $count >= 0 } {
                            set local_result(mSelectStatus) true
                            set local_result(mSelectCount) $count
                        } else {
                            set local_result(mSelectStatus) false
                        }
                    }
                    if { [$child hasAttribute reorderChildren] } {
                        set local_result(mReorder) \
                            [convert_to_bool [$child hasAttribute reorderChildren]]
                    }
                    if { [$child hasAttribute selectionTiming] } {
                        set timing [$child getAttribute selectionTiming]
                        # check vocabulary (according to ilias)
                        switch $timing {
                            onEachNewAttempt - once - never {
                                set local_result(mSelectTiming) $timing
                            }
                            default {
                                set local_result(mSelectTiming) never
                            }
                        }
                    }
                }
                "deliveryControls" {
                    if { [$child hasAttribute tracked] } {
                        set local_result(mIsTracked) \
                            [convert_to_bool [$child getAttribute tracked]]
                    }
                    if { [$child hasAttribute completionSetByContent] } {
                        set local_result(mContentSetsCompletion) \
                            [convert_to_bool [$child getAttribute completionSetByContent]]
                    }
                    if { [$child hasAttribute objectiveSetByContent] } {
                        set local_result(mContentSetsObj) \
                            [convert_to_bool [$child getAttribute objectiveSetByContent]]
                    }
                }
                "constrainedChoiceConsiderations" {
                    if { [$child hasAttribute preventActivation] } {
                        set local_result(mPreventActivation) \
                            [convert_to_bool [$child getAttribute preventActivation]]
                    }
                    if { [$child hasAttribute constrainChoice] } {
                        set local_result(mConstrainChoice) \
                            [convert_to_bool [$child getAttribute constrainChoice]]
                    }
                }
                "rollupConsiderations" {
                    if { [$child hasAttribute requiredForSatisfied] } {
                        set local_result(mRequiredForSatisfied) [$child getAttribute requiredForSatisfied]
                    }
                    if { [$child hasAttribute requiredForNotSatisfied] } {
                        set local_result(mRequiredForNotSatisfied) [$child getAttribute requiredForNotSatisfied]
                    }
                    if { [$child hasAttribute requiredForCompleted] } {
                        set local_result(mRequiredForCompleted) [$child getAttribute requiredForCompleted]
                    }
                    if { [$child hasAttribute requiredForIncomplete] } {
                        set local_result(mRequiredForImcomplete) [$child getAttribute requiredForIncomplete]
                    }
                    if { [$child hasAttribute measureSatisfactionIfActive] } {
                        set local_result(mActiveMeasure) \
                            [convert_to_bool [$child getAttribute measureSatisfactionIfActive]]
                    }
                }
            }
        }
    }
}

#
# Objectives
#

ad_proc scorm_importer::rte_activity_tree::get_objectives {
    -node:required
    -result:required
} {

    upvar $result local_result

    set objectives [list]
    set shortcuts [list]
    foreach child [$node childNodes] {
        if { [$child nodeType] eq "ELEMENT_NODE" } {
            if { [$child localName] eq "primaryObjective" || [$child localName] eq "objective" } {
                lappend objectives \
                    [scorm_importer::rte_activity_tree::seq_objective -node $child]
                # to build a json object, we need one big list
                set shortcuts \
                    [concat $shortcuts \
                         [scorm_importer::rte_activity_tree::objective_map_shortcut \
                              -node $child]]
            }
        }
    }

    if { [llength $objectives] } {
        set local_result(mObjectives) [util::json::array::create $objectives]
    } else {
        set local_result(mObjectives) null
    }

    if { [llength $shortcuts] } {
        set local_result(mObjMaps) [util::json::object::create $shortcuts]
    } else {
        set local_result(mObjMaps) null
    }

}

ad_proc scorm_importer::rte_activity_tree::seq_objective {
    -node:required
} {

    # default objective object
    array set objective [scorm_importer::rte_activity_tree::objective_attributes]

    if { [$node localName] eq "primaryObjective" } {
        set objective(mContributesToRollup) true
    }
    if { [$node hasAttribute "objectiveID"] } {
        set objective(mObjID) [$node getAttribute "objectiveID"]
    }
    if { [$node hasAttribute "satisfiedByMeasure"] } {
        set objective(mSatisfiedByMeasure) [$node getAttribute "objectiveID"]
    }
    if { [$node hasAttribute "minNormalizedMeasure"] } {
        set objective(mMinMeasure) [$node getAttribute "objectiveID"]
    }

    set maps [list]
    foreach child [$node getElementsByTagName "imsss:mapInfo"] {
        lappend maps \
            [scorm_importer::rte_activity_tree::seq_objective_map -node $child]
    }          

    if { [llength $maps] } {
        set objective(mMaps) [util::json::array::create $maps]
    } else {
        set objective(mMaps) null
    }

    return \
        [util::json::object::create \
             [list _SeqObjective \
                 [util::json::object::create [array get objective]]]]

}

ad_proc scorm_importer::rte_activity_tree::objective_map_shortcut {
    -node:required
} {

    set maps [list]
    if { [$node hasAttribute "objectiveID"] } {
        set objective_id [$node getAttribute "objectiveID"]
    }

    foreach child [$node getElementsByTagName "imsss:mapInfo"] {
        lappend maps \
            [scorm_importer::rte_activity_tree::seq_objective_map -node $child]
    }

    if { [llength $maps] } {
        return [list $objective_id \
                    [util::json::array::create $maps]]
    } else {
        return ""
    }
}

ad_proc scorm_importer::rte_activity_tree::seq_objective_map {
    -node:required
} {

    # default map object
    array set map [scorm_importer::rte_activity_tree::map_attributes]

    if { [$node hasAttribute "targetObjectiveID"] } {
        set map(mGlobalObjID) [$node getAttribute "targetObjectiveID"]
    }
    if { [$node hasAttribute "readSatisfiedStatus"] } {
        set map(mReadStatus) [$node getAttribute "readSatisfiedStatus"]
    }
    if { [$node hasAttribute "readNormalizedMeasure"] } {
        set map(mReadMeasure) [$node getAttribute "readNormalizedMeasure"]
    }
    if { [$node hasAttribute "writeSatisfiedStatus"] } {
        set map(mWriteStatus) [$node getAttribute "writeSatisfiedStatus"]
    }
    if { [$node hasAttribute "writeNormalizedMeasure"] } {
        set map(mWriteMeasure) [$node getAttribute "writeNormalizedMeasure"]
    }

    return \
        [util::json::object::create \
            [list _SeqObjectiveMap \
                [util::json::object::create [array get map]]]]
}

#
# Sequencing Rules
#

ad_proc scorm_importer::rte_activity_tree::get_sequencing_rules {
    -node:required
    -result:required
} {

    upvar $result local_result

    set pre_rules [list]
    set exit_rules [list]
    set post_rules [list]

    foreach child [$node childNodes] {
        if { [$child nodeType] eq "ELEMENT_NODE" } {
            switch [$child localName] {
                "preConditionRule" {
                    lappend pre_rules \
                        [scorm_importer::rte_activity_tree::seq_rule -node $child]
                }
                "exitConditionRule" {
                    lappend exit_rules \
                        [scorm_importer::rte_activity_tree::seq_rule -node $child]
                }
                "postConditionRule" {
                    lappend post_rules \
                        [scorm_importer::rte_activity_tree::seq_rule -node $child]
                }
            }          
        }
    }

    # nothing in a _SeqRuleset object except mRules so we create everything here
    if { [llength $pre_rules] } {
        set local_result(mPreConditionRules) \
            [util::json::object::create \
                 [list _SeqRuleset \
                      [util::json::object::create \
                           [list mRules \
                                [util::json::array::create $pre_rules]]]]]
    } else {
        set local_result(mPreConditionRules) null
    }

    if { [llength $exit_rules] } {
        set local_result(mExitActionRules) \
            [util::json::object::create \
                 [list _SeqRuleset \
                      [util::json::object::create \
                           [list mRules \
                                [util::json::array::create $exit_rules]]]]]
    } else {
        set local_result(mExitActionRules) null
    }

    if { [llength $post_rules] } {
        set local_result(mPostConditionRules) \
            [util::json::object::create \
                 [list _SeqRuleset \
                      [util::json::object::create \
                           [list mRules \
                                [util::json::array::create $post_rules]]]]]
    } else {
        set local_result(mPostConditionRules) null
    }
    
}

ad_proc scorm_importer::rte_activity_tree::seq_rule {
    -node:required
} {
    array set rule [scorm_importer::rte_activity_tree::seq_rule_attributes]

    set condition_sets [list]
    foreach child [$node childNodes] {
        if { [$child nodeType] eq "ELEMENT_NODE" } {
            switch [$child localName] {
                "ruleConditions" {
                    # concat rather than append - since we're making a json object, we need one long list
                    set condition_sets \
                        [concat $condition_sets \
                             [scorm_importer::rte_activity_tree::seq_condition_set \
                                  -node $child -rule_type "sequencing"]]
                }
                "ruleAction" {
                    if { [$child hasAttribute "action"] } {
                        set rule(mAction) [$child getAttribute "action"]
                    }
                }
            }
        }
    }

    if { [llength $condition_sets] } {
        set rule(mConditions) \
            [util::json::object::create \
                 [list _SeqConditionSet $condition_sets]]
    } else {
        set rule(mConditions) null
    }

    return \
        [util::json::object::create \
            [list _SeqRule \
                [util::json::object::create [array get rule]]]]
}


#
# Rollup Rules
#

ad_proc scorm_importer::rte_activity_tree::get_rollup_rules {
    -node:required
    -result:required
} {

    upvar $result local_result

    if { [$node hasAttribute "rollupObjectiveSatisfied"] } {
        set local_result(mIsObjectiveRolledUp) [$node getAttribute "rollupObjectiveSatisfied"]
    }
    if { [$node hasAttribute "objectiveMeasureWeight"] } {
        set local_result(mObjMeasureWeight) [$node getAttribute "objectiveMeasureWeight"]
    }
    if { [$node hasAttribute "rollupProgressCompletion"] } {
        set local_result(mIsProgressRolledUp) [$node getAttribute "rollupProgressCompletion"]
    }

    array set rollup_ruleset [scorm_importer::rte_activity_tree::rollup_ruleset_attributes]

    set rollup_rules [list]
    foreach child [$node getElementsByTagName "imsss:rollupRule"] {
        lappend rollup_rules \
            [scorm_importer::rte_activity_tree::seq_rollup_rule -node $child]
    }

    if { [llength $rollup_rules] } {
        set rollup_ruleset(mRollupRules) [util::json::array::create $rollup_rules]
        set local_result(mRollupRules) \
            [util::json::object::create \
                 [list _SeqRollupRuleset \
                      [util::json::object::create \
                           [array get rollup_ruleset]]]]
    } else {
        set local_result(mRollupRules) null
    }
}

ad_proc scorm_importer::rte_activity_tree::seq_rollup_rule {
    -node:required
} {

    # default rule object
    array set rule [scorm_importer::rte_activity_tree::rollup_rule_attributes]

    if { [$node hasAttribute "childActivitySet"] } {
        set rule(mChildActivitySet) [$node getAttribute "childActivitySet"]
    }
    if { [$node hasAttribute "minimumCount"] } {
        set rule(mMinCount) [$node getAttribute "minimumCount"]
    }
    if { [$node hasAttribute "minimumPercent"] } {
        set rule(mMinPercent) [$node getAttribute "minimumPercent"]
    }

    set condition_sets [list]
    foreach child [$node childNodes] {
        if { [$child nodeType] eq "ELEMENT_NODE" } {
            switch [$child localName] {
                "rollupConditions" {
                    # concat rather than append - since we're making a json object, we need one long list
                    set condition_sets \
                        [concat $condition_sets \
                             [scorm_importer::rte_activity_tree::seq_condition_set \
                                  -node $child -rule_type "rollup"]]
                }
                "rollupAction" {
                    if { [$child hasAttribute "action"] } {
                        switch [$child getAttribute "action"] {
                            "satisfied" {
                                set rule(mAction) 1
                            }
                            "notSatisfied" {
                                set rule(mAction) 2
                            }
                            "completed" {
                                set rule(mAction) 3
                            }
                            "incomplete" {
                                set rule(mAction) 4
                            }
                        }
                    }
                }
            }
        }
    }

    if { [llength $condition_sets] } {
        set rule(mConditions) \
            [util::json::object::create \
                 [list _SeqConditionSet $condition_sets]]
    } else {
        set rule(mConditions) null
    }

    return \
        [util::json::object::create \
            [list _SeqRollupRule \
                [util::json::object::create [array get rule]]]]

}

#
# Conditions
#

ad_proc scorm_importer::rte_activity_tree::seq_condition_set {
    -node:required
    -rule_type:required
} {

    array set condition_set [scorm_importer::rte_activity_tree::condition_set_attributes]

    switch $rule_type {
        "sequencing" {
            set condition_set(mRollup) false
            set condition_set(mCombination) all
            set tag_name "imsss:ruleCondition"
        }
        "rollup" {
            set condition_set(mRollup) true
            set condition_set(mCombination) any
            set tag_name "imsss:rollupCondition"
        }
    }

    # override with manifest data if exists
    if { [$node hasAttribute "conditionCombination"] } {
        set condition_set(mCombination) [$node getAttribute "conditionCombination"]
    }

    set conditions [list]
    foreach child [$node getElementsByTagName $tag_name] {
        lappend conditions \
            [scorm_importer::rte_activity_tree::seq_condition \
                 -node $child -rule_type $rule_type]
    }

    if { [llength $conditions] } {
        set condition_set(mConditions) [util::json::array::create $conditions]
    } else {
        set condition_set(mConditions) null
    }

    return [util::json::object::create [array get condition_set]]

}

ad_proc scorm_importer::rte_activity_tree::seq_condition {
    -node:required
    -rule_type:required
} {

    array set condition [scorm_importer::rte_activity_tree::condition_attributes]
    if { [$node hasAttribute "condition"] } {
        set condition(mCondition) [$node getAttribute "condition"]
    }
    if { [$node hasAttribute "operator"] } {
        set condition(mNot) \
            [ad_decode [$node getAttribute "operator"] not true false]
    }

    if { $rule_type eq "sequencing" } {
        if { [$node hasAttribute "referencedObjective"] } {
            set condition(mObjID) [$node getAttribute "referencedObjective"]
        }
        if { [$node hasAttribute "measureThreshold"] } {
            set condition(mThreshold) [$node getAttribute "measureThreshold"]
        }
    }

    return \
        [util::json::object::create \
            [list _SeqCondition \
                [util::json::object::create [array get condition]]]]
}

#
# Auxiliary Resources
#

ad_proc scorm_importer::rte_activity_tree::get_auxiliary_resources {
    -node:required
    -result:required
} {
    upvar $result local_result

    set resources [list]
    foreach child [$node getElementsByTagName "auxiliaryResource"] {
        lappend resources \
            [scorm_importer::rte_activity_tree::auxiliary_resource -node $child]
    }

    if { [llength $resources] } {
        set local_result(mAuxResources) \
            [util::json::object::create \
                 [list _ADLAuxiliaryResource \
                      [util::json::array::create $resources]]]
    } else {
        set local_result(mAuxResources) null
    }
}

ad_proc scorm_importer::rte_activity_tree::auxiliary_resource {
    -node:required
} {

    array set resource [scorm_importer::rte_activity_tree::auxiliary_resource_attributes]
    if { [$node hasAttribute "purpose"] } {
        set resource(mType) [$node getAttribute "purpose"]
    }
    if { [$node hasAttribute "auxiliaryResourceID"] } {
        set resource(mResourceID) [$node getAttribute "auxiliaryResourceID"]
    }
    return [util::json::object::create [array get resource]]
}

# helper proc (from ilias)
ad_proc scorm_importer::rte_activity_tree::convert_to_bool {
    string
} {
    if { [string toupper $string] eq "FALSE" } {
      return false
    } else {
      return true
    }
}


# "object" constructors
ad_proc scorm_importer::rte_activity_tree::objective_attributes { } {
    provide basic constructor for objectives
} {
    return {
        mObjID _primary_
        mSatisfiedByMeasure false
        mActiveMeasure true
        mMinMeasure 1.0
        mContributesToRollup false
    }
}

ad_proc scorm_importer::rte_activity_tree::map_attributes { } {
    provide basic constructor for objective maps
} {
    return {
        mGlobalObjID null
        mReadStatus true
        mReadMeasure true
        mWriteStatus false
        mWriteMeasure false
    }
}

ad_proc scorm_importer::rte_activity_tree::activity_attributes { } {
    constructor for activity
} {

    return {
        mPreConditionRules null
        mPostConditionRules null
        mExitActionRules null
        mXML null
        mDepth 0
        mCount -1
        mLearnerID _NULL_
        mScopeID null
        mActivityID null
        mResourceID null
        mStateID null
        mTitle null
        mIsVisible true
        mOrder -1
        mActiveOrder -1
        mSelected true
        mParent null
        mIsActive false
        mIsSuspended false
        mChildren null
        mActiveChildren null
        mDeliveryMode normal
        mControl_choice true
        mControl_choiceExit true
        mControl_flow false
        mControl_forwardOnly false
        mConstrainChoice false
        mPreventActivation false
        mUseCurObj true
        mUseCurPro true
        mMaxAttemptControl false
        mMaxAttempt 0
        mAttemptAbDurControl false
        mAttemptAbDur null
        mAttemptExDurControl false
        mAttemptExDur null
        mActivityAbDurControl false
        mActivityAbDur null
        mActivityExDurControl false
        mActivityExDur null
        mBeginTimeControl false
        mBeginTime null
        mEndTimeControl false
        mEndTime null
        mAuxResources null
        mRollupRules null
        mActiveMeasure true
        mRequiredForSatisfied always
        mRequiredForNotSatisfied always
        mRequiredForCompleted always
        mRequiredForIncomplete always
        mObjectives null
        mObjMaps null
        mIsObjectiveRolledUp true
        mObjMeasureWeight 1.0
        mIsProgressRolledUp true
        mSelectTiming never
        mSelectStatus false
        mSelectCount 0
        mSelection false
        mRandomTiming never
        mReorder false
        mRandomized false
        mIsTracked true
        mContentSetsCompletion false
        mContentSetsObj false
        mCurTracking null
        mTracking null
        mNumAttempt 0
        mNumSCOAttempt 0
        mActivityAbDur_track null
        mActivityExDur_track null
    }
}

ad_proc scorm_importer::rte_activity_tree::seq_rule_attributes { } {
    provide basic constructor for sequencing rule
} {
    return { 
        mAction ignore
        mConditions null
    }
}

ad_proc scorm_importer::rte_activity_tree::rollup_rule_attributes { } {
    provide basic constructor for rollup rule
} {
    return { 
        mAction 1
        mChildActivitySet all
        mMinCount 0
        mMinPercent 0.0
        mConditions null
    }
}

ad_proc scorm_importer::rte_activity_tree::rollup_ruleset_attributes { } {
    provide basic constructor for rollup rulesets
} {
    return {
        mRollupRules null
        mIsSatisfied false
        mIsNotSatisfied false
        mIsCompleted false
        mIsIncomplete false
    }
}

ad_proc scorm_importer::rte_activity_tree::condition_set_attributes { } {
    provide basic constructor for sequence condition sets
} {
    return {
        mCombination null
        mConditions null
        mRetry false
        mRollup false
    }
}

ad_proc scorm_importer::rte_activity_tree::condition_attributes { } {
    provide basic constructor for sequence conditions
} {
    return {
        mCondition null
        mNot false
        mObjID null
        mThreshold 0.0
    }
}

ad_proc scorm_importer::rte_activity_tree::control_mode_attributes {
    -node:required
} {
    provide basic constructor for control mode
} {
    return {
        choice true
        flow true
    }
}

ad_proc scorm_importer::rte_activity_tree::auxiliary_resource_attributes {
    -node:required
} {
    provide basic constructor for auxiliary resources
} {
    return {
        mType null
        mResourceID null
        mParameter null
    }
}

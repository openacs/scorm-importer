ad_page_contract {

    Upload and imports an IMS Content Package file
    Initial form data

    @author Ernie Ghiglione (ErnieG@mm.st)
    @creation-date 19 March 2003
    @cvs-id $Id$

} {
    return_url:notnull
}

ad_form -name package_upload -export {return_url} -action import-2 -html {enctype multipart/form-data} -form {
    {default_lesson_mode:text(select)
        {label "[_ scorm-importer.Default_Lesson_Mode]"}
        {options {{"[_ scorm-importer.Normal]" normal}
                  {"[_ scorm-importer.Browse]" browse}}
        }
        {value browse}
    }
    {online:text(select)
        {label "[_ scorm-importer.Online]"}
        {options {{"[_ scorm-importer.No]" f}
                  {"[_ scorm-importer.Yes]" t}}
        }
        {value f}
    }
    {upload_file:file
        {label "[_ scorm-importer.Select_course]"}
    }
}

ad_return_template



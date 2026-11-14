:- begin_tests(agentprolog_images).
:- use_module('../prolog/agentprolog_images').
config(_{runtime_options:[image_inputs(true),provider(provider(openai_compatible,[]))],mode:direct}).
png(_{name:"pixel.png",mime:"image/png",data:"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="}).
test(actual_data_and_reference) :- config(C),png(I),image_request(C,[I],[P],[R]),assertion(R.bytes>8),string_length(R.sha256,64),assertion(sub_string(P.image_url.url,0,22,_,"data:image/png;base64,")).
test(disabled_rejects,[throws(error(invalid_or_unsupported_image_input,_))]) :- png(I),image_request(_{runtime_options:[]},[I],_,_).
test(url_not_allowed,[throws(error(invalid_or_unsupported_image_input,_))]) :- config(C),image_request(C,[_{name:"x.png",mime:"image/png",data:"https://example.com/a.png"}],_,_).
test(path_name_not_allowed,[throws(error(invalid_or_unsupported_image_input,_))]) :- config(C),png(I),put_dict(name,I,"../secret",Bad),image_request(C,[Bad],_,_).
test(multiple_images_rejected,[throws(error(invalid_or_unsupported_image_input,_))]) :- config(C),png(I),image_request(C,[I,I],_,_).
test(custom_handler_rejected,[throws(error(invalid_or_unsupported_image_input,_))]) :- config(C),png(I),put_dict(runtime_options,C,[image_inputs(true),provider(provider(openai_compatible,[])),model_handler(test:handler)],Bad),image_request(Bad,[I],_,_).
:- end_tests(agentprolog_images).

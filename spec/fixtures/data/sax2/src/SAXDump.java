import org.xml.sax.*;
import org.xml.sax.ext.*;
import org.xml.sax.helpers.*;


/**
 * Poke at parsers and find out what features and properties
 * they support, using the SAX2 (+extensions) standard list.
 *
 * @author David Brownell
 * @version $Id: SAXDump.java,v 1.3 2002/07/29 23:07:40 dbrownell Exp $
 */
public class SAXDump
{
    private SAXDump () { }
    
    /**
     * Pass a list of parser classes; each will be scanned.
     * If not, parsers from a built-in list are scanned.
     */
    public static void main (String argv [])
    {
	if (argv.length == 0)
	    argv = new String [] {
		"com.jclark.xml.sax.SAX2Driver",
		"gnu.xml.aelfred2.SAXDriver",
		"gnu.xml.aelfred2.XmlReader",
		"gnu.xml.util.DomParser",
		"oracle.xml.parser.v2.SAXParser",
		"org.apache.crimson.parser.XMLReaderImpl",
		"org.apache.xerces.parsers.SAXParser",
		};

	for (int i = 0; i < argv.length; i++)
	    checkParser (argv [i]);
    }

    private static final String		FEATURE_URI
	= "http://xml.org/sax/features/";

    private static final String		PROPERTY_URI
	= "http://xml.org/sax/properties/";
    
    //////////////////////////////////////////////////////////////////

    private static void
    checkFeature (String id, XMLReader producer)
    {
	int	state = 0;

	try {
	    boolean	value;

	    // align to longest id...
	    final int	align = 35;

	    for (int i = align - id.length (); i > 0; i--)
		System.out.print (' ');
	    System.out.print (id);
	    System.out.print (":  ");

	    id = FEATURE_URI + id;

	    value = producer.getFeature (id);
	    System.out.print (value);
	    System.out.print (", ");
	    state = 1;

	    producer.setFeature (id, value);
	    state = 2;

	    producer.setFeature (id, !value);
	    System.out.println ("read and write");

	    // changes value and leaves it

	} catch (SAXNotSupportedException e) {
	    switch (state) {
	      case 0: System.out.println ("(can't read now)"); break;
		/* bogus_1 means can't reassign the default;
		 * probably intended to be read/write
		 */
	      case 1: System.out.println ("bogus_1"); break;
	      case 2: System.out.println ("readonly"); break;
	    }
	    
	} catch (SAXNotRecognizedException e) {
	    if (state == 0) 
		System.out.println ("(unrecognized)");
	    else
		/* bogus_2 means the wrong exception was thrown */
		System.out.println ("bogus_2");
	}
    }

    private static void
    showFeatures (XMLReader producer)
    {
	System.out.println ("FEATURES for "
	    + producer.getClass ().getName ());

	// must-have, default=false
	checkFeature ("namespace-prefixes", producer);
	// must-have, default=true
	checkFeature ("namespaces", producer);

	// lots of optional features
	checkFeature ("external-general-entities", producer);
	checkFeature ("external-parameter-entities", producer);
	checkFeature ("is-standalone", producer);
	checkFeature ("lexical-handler/parameter-entities", producer);
	checkFeature ("resolve-dtd-uris", producer);
	checkFeature ("string-interning", producer);
	checkFeature ("use-attributes2", producer);
	checkFeature ("use-locator2", producer);
	checkFeature ("validation", producer);
    }

    //////////////////////////////////////////////////////////////////

    private static void
    checkProperty (String id, XMLReader producer, Object newValue)
    {
	int	state = 0;

	try {
	    Object	value;

	    // align to longest id...
	    final int	align = 20;

	    for (int i = align - id.length (); i > 0; i--)
		System.out.print (' ');
	    System.out.print (id);
	    System.out.print (":  ");

	    id = PROPERTY_URI + id;

	    value = producer.getProperty (id);
	    System.out.print (value);
	    System.out.print (", ");
	    state = 1;

	    producer.setProperty (id, value);
	    state = 2;

	    producer.setProperty (id, newValue);
	    System.out.println ("read and write");

	    // changes value and leaves it

	} catch (SAXNotSupportedException e) {
	    switch (state) {
	      case 0: System.out.println ("(can't read now)"); break;
		/* bogus_1 means can't reassign the default;
		 * probably intended to be read/write
		 */
	      case 1: System.out.println ("bogus_1"); break;
	      case 2: System.out.println ("readonly"); break;
	    }
	    
	} catch (SAXNotRecognizedException e) {
	    if (state == 0) 
		System.out.println ("(unrecognized)");
	    else
		/* bogus_2 means the wrong exception was thrown */
		System.out.println ("bogus_2");
	}
    }

    private static void
    showProperties (XMLReader producer)
    {
	System.out.println ("PROPERTIES for "
	    + producer.getClass ().getName ());

	DefaultHandler2		handler = new DefaultHandler2 ();

	// all properties are optional
	checkProperty ("declaration-handler", producer, handler);

    // To check the dom-node property, we need an instance
    // of an org.w3c.dom.Node.  Any one will do; but since
    // we don't know what is installed, we try four likely
    // suspects.

    String[] domClassNames = {
        "org.apache.crimson.tree.XmlDocument",
        "org.apache.xerces.dom.DocumentImpl",
        "gnu.xml.dom.DomDocument",
        "oracle.xml.parser.v2.XMLDocument",
    };
    org.w3c.dom.Node node = null;
    for (int i = 0; i < domClassNames.length; i++) {
        try {
            Class domClass = Class.forName(domClassNames[i]);
            node = (org.w3c.dom.Node) domClass.newInstance();
        }
        catch (ClassNotFoundException e) { continue; }
        catch (InstantiationException e) { continue; }
        catch (IllegalAccessException e) { continue; }
        catch (ClassCastException e)     { continue; }
    }

    // If none of the classes yielded a workable instance,
    // just skip the test.
    if (node != null) {
        checkProperty ("dom-node", producer, node);
    }

	checkProperty ("lexical-handler", producer, handler);
	checkProperty ("xml-string", producer, "<root/>");
    }

    //////////////////////////////////////////////////////////////////

    private static void
    checkParser (String classname)
    {
	XMLReader	producer = null;

	try {
	    producer = XMLReaderFactory.createXMLReader (classname);

	    showFeatures (producer);
	    System.out.println ("");
	    showProperties (producer);

	} catch (Exception e) {
	    if (producer == null)
		System.err.println ("(can't create " + classname + ")");
	    else
		e.printStackTrace ();
	} finally {
	    System.out.println ("");
	}
    }
}
